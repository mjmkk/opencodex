import { readFileSync } from 'node:fs';
import { execFile } from 'node:child_process';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHttpServer } from './http-server.js';
import { desktopService } from './desktop-mobile-service.js';
import { SqliteStore } from './sqlite-store.js';
import { ApnsNotifier } from './apns-notifier.js';
import { LiveActivities } from './live-activities.js';
import { DesktopRelayClient } from './desktop-relay-client.js';
import { createNativeControlTargets, closeNativeControlTargets } from './native-control-targets.js';

const require = createRequire(import.meta.url);
const mirrorAdapter = fileURLToPath(new URL('../../mirror/adapter.py', import.meta.url));
const { createMirrorRoutes } = require('../../mirror/mirror-routes.js');
const { createOverviewRoutes } = require('./goal-overview-routes.cjs');
const { createHarnessTreeRoutes } = require('./harness-tree-routes.cjs');
const config = JSON.parse(readFileSync(process.env.OPENCODEX_MOBILE_CONFIG, 'utf8'));
if (typeof config.authToken !== 'string' || config.authToken.length < 24)
  throw new Error('Existing authenticated mobile configuration is required');
if (!config.mirror?.namespace || !config.mirror?.dsn)
  throw new Error('Mirror namespace and local connection must be configured');

const mirror = input => new Promise(resolve => {
  const child = execFile(config.mirror.python ?? '/home/spirit/agt28-mirror/.venv/bin/python',
    [mirrorAdapter], {timeout:15000,maxBuffer:16*1024*1024,
      env:{PATH:'/usr/bin:/bin',LANG:'C.UTF-8',MIRROR_NAMESPACE:config.mirror.namespace,MIRROR_DSN:config.mirror.dsn, ...(config.mirror.blobRoot ? {MIRROR_BLOBS: config.mirror.blobRoot} : {}), PYTHONDONTWRITEBYTECODE:'1'}},
    (error,stdout)=>{
      try { resolve(error ? {ok:false} : JSON.parse(stdout)); }
      catch { resolve({ok:false}); }
    });
  child.stdin.on('error',()=>{});
  child.stdin.end(JSON.stringify(input));
});
const store = new SqliteStore({dbPath:config.dbPath});
store.init();
const native = config.native?.args ? new DesktopRelayClient(config.native) : null;
const nativeControlTargets = createNativeControlTargets(config.nativeControlTargets);
const service = desktopService({mirror,store,native,nativeControlTargets});
const notifier = config.apns?.enabled ? new ApnsNotifier({...config.apns,db:store.db}) : null;
const liveActivities = notifier ? new LiveActivities({db:store.db,notifier,service}) : null;
const mirrorRoutes = createMirrorRoutes(config.mirror);
const overviewRoutes = config.overview?.enabled ? createOverviewRoutes({
  namespace: config.mirror.namespace, dsn: config.mirror.dsn,
  cachePath: config.dbPath, adapterPath: config.overview.adapterPath,
  python: config.overview.python ?? '/home/spirit/agt28-mirror/.venv/bin/python',
}) : null;
const harnessTreeRoutes = createHarnessTreeRoutes({ namespace: config.mirror.namespace, dsn: config.mirror.dsn,
  python: config.overview?.python ?? '/home/spirit/agt28-mirror/.venv/bin/python' });
const mobileRoutes = async (req, res) => {
  if (await mirrorRoutes(req, res)) return true;
  if (await harnessTreeRoutes(req, res)) return true;
  return overviewRoutes ? await overviewRoutes(req, res) : false;
};
const server = createHttpServer({service,authToken:config.authToken,mobileMetricsDb:store.db,
  nativeRequests:native ? native.call.bind(native) : null,
  mobileRoutes,liveActivities,
  logger:{error:()=>console.error('mobile_request_failed')}});
await server.listen(config.port ?? 8789,'127.0.0.1');
let overviewCoordinator = null;
// Trusted startup configuration only. Default is disabled; GET stays cache-only.
if (config.overview?.refresh?.enabled === true) {
  try {
    const settings = config.overview.refresh;
    const { startCoordinator } = require(path.join(settings.consumerRoot,
      'runtime/overview/mobile-observer.cjs'));
    overviewCoordinator = startCoordinator({
      ...settings, enabled: true,
      namespace: config.mirror.namespace, dsn: config.mirror.dsn, cachePath: config.dbPath,
      python: settings.python ?? config.overview.python ?? '/home/spirit/agt28-mirror/.venv/bin/python',
    }, { onStatus: state => {
      if (state.status === 'completed' && state.counts?.model_calls === 0) return;
      console.log(JSON.stringify({ event: 'overview_observer_cycle', status: state.status,
        counts: state.counts }));
    } });
  } catch { console.error('overview_coordinator_unavailable'); }
}
console.log(JSON.stringify({event:'mobile_listening',port:config.port ?? 8789,
  mirror:true,nativeConfigured:!!native,apnsConfigured:!!notifier}));
const stopActivities=liveActivities?.start({warn:()=>console.error('activity_observation_unavailable')});
let closing = null;
function close() {
  if (closing !== null) return closing;
  closing = (async () => {
    stopActivities?.();
    // Stop only our observer child and wait before closing the shared cache.
    await overviewCoordinator?.stop();
    closeNativeControlTargets(nativeControlTargets);
    native?.close();notifier?.close();await server.close();store.close();process.exit(0);
  })();
  return closing;
}
process.once('SIGTERM',close);process.once('SIGINT',close);
