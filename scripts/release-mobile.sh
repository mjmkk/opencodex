#!/bin/sh
# 把当前 HEAD 的服务端代码发布到 spirit-master 的 opencodex-mobile。
# 新 release = 复制上一版（保留 node_modules / runtime / python / overview），
# 再用这个 commit 的 codex-worker-mvp/src、mirror、mirror_backend 整体替换。
# 重启失败或 /health 不通就切回上一版。
set -eu
cd "$(git rev-parse --show-toplevel)"
test -z "$(git status --porcelain -- codex-worker-mvp/src mirror mirror_backend)" || { echo "服务端代码有未提交改动" >&2; exit 1; }
commit=$(git rev-parse HEAD)
name="$(date +%Y%m%d-%H%M)-$(git rev-parse --short=8 HEAD)"
SSH="ssh -F $HOME/.ssh/spirit_fleet_config agt-master"

tarball="/tmp/opencodex-mobile-$name.tar"
git archive "$commit" codex-worker-mvp/src mirror mirror_backend | $SSH "cat > $tarball"
$SSH "sh -s -- '$name' '$commit' '$tarball'" <<'REMOTE'
set -eu
root=/opt/spirit/opencodex-mobile
prev=$(readlink -f "$root/current")
rel="$root/releases/$1"
test ! -e "$rel"
stage=$(mktemp -d)
trap 'rm -rf "$stage" "$3"' EXIT
tar -x -C "$stage" -f "$3"
for f in "$stage"/codex-worker-mvp/src/*.js "$stage"/codex-worker-mvp/src/*.cjs "$stage"/codex-worker-mvp/src/*.mjs "$stage"/mirror/*.js; do
  "$prev/runtime/bin/node" --check "$f"
done
sudo -n mkdir "$rel"
sudo -n cp -a "$prev/." "$rel/"
sudo -n rm -rf "$rel/codex-worker-mvp/src" "$rel/mirror" "$rel/mirror_backend"
sudo -n cp -R "$stage/codex-worker-mvp/src" "$rel/codex-worker-mvp/src"
sudo -n cp -R "$stage/mirror" "$stage/mirror_backend" "$rel/"
echo "$2" | sudo -n tee "$rel/RELEASE_COMMIT" >/dev/null
sudo -n chown -R root:root "$rel/codex-worker-mvp/src" "$rel/mirror" "$rel/mirror_backend" "$rel/RELEASE_COMMIT"
sudo -n chmod -R a-w,a+rX "$rel/codex-worker-mvp/src" "$rel/mirror" "$rel/mirror_backend"

switch() { sudo -n ln -sfn "$1" "$root/current.next"; sudo -n mv -Tf "$root/current.next" "$root/current"; }
healthy() { for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sf -o /dev/null http://127.0.0.1:8789/health && return 0; sleep 1; done; return 1; }
switch "$rel"
if systemctl --user restart opencodex-mobile && healthy; then
  echo "released $rel (previous $prev)"
else
  switch "$prev"; systemctl --user restart opencodex-mobile
  echo "发布失败，已切回 $prev" >&2; exit 1
fi
REMOTE
