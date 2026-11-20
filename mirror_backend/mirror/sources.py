"""Source identity classification shared by offline readers."""

def source_format(namespace):
    if isinstance(namespace, str):
        for prefix, name in (("codex-backup:", "codex_backup"),
                             ("chatgpt-export:", "chatgpt_export")):
            if namespace.startswith(prefix) and namespace[len(prefix):]:
                return name
    return None


def is_offline_source(namespace):
    return source_format(namespace) is not None
