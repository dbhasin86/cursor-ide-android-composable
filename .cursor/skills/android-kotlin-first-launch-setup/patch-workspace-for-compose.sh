#!/usr/bin/env bash
#Patch workspace.json for Kotlin LSP in Cursor:
#1) Compose compiler plugin - fixes false "Argument type mismatch" / Composable lambda errors.
#2) Attach source JARs from Gradle cache - Go to Definition shows full source + KDoc instead of decompiler stubs.
#Run from project root after: adt-cli workspace . --output ./workspace.json
#workspace.json is in .gitignore.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_JSON="$PROJECT_ROOT/workspace.json"
GRADLE_CACHES="${GRADLE_USER_HOME:-$HOME/.gradle}/caches"

if [[ ! -f "$WORKSPACE_JSON" ]]; then
  echo "workspace.json not found at $WORKSPACE_JSON"
  echo "Generate it first: JAVA_HOME=\$(/usr/libexec/java_home -v 21) adt-cli workspace . --output ./workspace.json"
  exit 1
fi

JAR=$(find "$GRADLE_CACHES" -name "kotlin-compose-compiler-plugin-embeddable*.jar" 2>/dev/null | head -1)
if [[ -z "$JAR" ]]; then
  echo "Compose compiler plugin JAR not found in $GRADLE_CACHES"
  echo "Run a Gradle build once (e.g. ./gradlew assembleDebug) so the plugin is cached."
  exit 1
fi

WORKSPACE_JSON="$WORKSPACE_JSON" COMPOSE_JAR="$JAR" PROJECT_ROOT="$PROJECT_ROOT" GRADLE_CACHES="$GRADLE_CACHES" python3 << 'PY'
import os
import sys

workspace_path = os.environ.get("WORKSPACE_JSON")
jar_path = os.environ.get("COMPOSE_JAR")
project_root = os.environ.get("PROJECT_ROOT", "")
if not workspace_path or not jar_path:
    sys.exit(1)

with open(workspace_path, "r") as f:
    content = f.read()

compose_already = '"kotlinSettings" : [ {' in content and '"sourceRoots"' in content and 'compilerArguments' in content and 'pluginClasspaths' in content
if compose_already:
    print("workspace.json already has Compose compiler plugin.")
else:
    old = '"kotlinSettings" : [ ]'
    jar_escaped = jar_path.replace("\\", "\\\\").replace('"', '\\"')
    #Kotlin LSP expects JPS serialization format (J{...}); -Xplugin= causes "Invalid serialization format"
    compiler_args = 'J{\\"jvmTarget\\":\\"21\\",\\"pluginOptions\\":[],\\"pluginClasspaths\\":[\\"' + jar_escaped + '\\"]}'
    #Source roots for app module (absolute paths)
    app_java = os.path.join(project_root, "app", "src", "main", "java").replace("\\", "/")
    app_kotlin = os.path.join(project_root, "app", "src", "main", "kotlin").replace("\\", "/")
    new = '''"kotlinSettings" : [ {
    "name" : "Kotlin",
    "sourceRoots" : [ "''' + app_java + '''", "''' + app_kotlin + '''" ],
    "configFileItems" : [ ],
    "module" : "app",
    "useProjectSettings" : false,
    "implementedModuleNames" : [ ],
    "dependsOnModuleNames" : [ ],
    "additionalVisibleModuleNames" : [ ],
    "productionOutputPath" : null,
    "testOutputPath" : null,
    "sourceSetNames" : [ ],
    "isTestModule" : false,
    "externalProjectId" : "app",
    "isHmppEnabled" : true,
    "pureKotlinSourceFolders" : [ ],
    "kind" : "default",
    "compilerArguments" : "''' + compiler_args + '''",
    "additionalArguments" : null,
    "scriptTemplates" : null,
    "scriptTemplatesClasspath" : null,
    "outputDirectoryForJsLibraryFiles" : null,
    "targetPlatform" : null,
    "externalSystemRunTasks" : [ ],
    "version" : 5,
    "flushNeeded" : false
  } ]'''

    if old not in content:
        print("workspace.json format may have changed (kotlinSettings not found or already patched).")
        sys.exit(1)
    content = content.replace(old, new)
    with open(workspace_path, "w") as f:
        f.write(content)
    print("Patched workspace.json with Compose compiler plugin.")

#Attach Gradle cache source JARs to libraries so Go to Definition shows full source + KDoc
import json
import glob

gradle_caches = os.environ.get("GRADLE_CACHES", "")
if gradle_caches:
    with open(workspace_path, "r") as f:
        data = json.load(f)
    modules_dir = os.path.join(gradle_caches, "modules-2", "files-2.1")
    attached = 0
    for lib in data.get("libraries", []):
        roots = lib.get("roots") or []
        props = (lib.get("properties") or {}).get("attributes") or {}
        g = props.get("groupId")
        a = props.get("artifactId")
        v = props.get("version")
        if not (g and a and v) or any(r.get("type") == "SOURCES" for r in roots):
            continue
        #Gradle path: modules-2/files-2.1/groupId/artifactId/version/ (groupId keeps dots)
        base = os.path.join(modules_dir, g, a, v)
        if not os.path.isdir(base):
            continue
        #Prefer <artifactId>-<version>-sources.jar, then any *-sources.jar (skip *-samples-*)
        candidates = []
        for sub in os.listdir(base):
            subpath = os.path.join(base, sub)
            if not os.path.isdir(subpath):
                continue
            for j in glob.glob(os.path.join(subpath, "*-sources.jar")):
                if "samples" not in os.path.basename(j).lower():
                    candidates.append(j)
        main_sources = [c for c in candidates if os.path.basename(c) == "%s-%s-sources.jar" % (a, v)]
        source_jar = (main_sources or candidates)[0] if candidates else None
        if source_jar:
            source_jar = os.path.normpath(os.path.abspath(source_jar))
            roots.append({"path": source_jar, "type": "SOURCES"})
            attached += 1
    if attached:
        with open(workspace_path, "w") as f:
            json.dump(data, f, indent=2)
        print("Attached source JARs for %d libraries. Reload the window so Kotlin LSP picks it up." % attached)
    else:
        print("Reload the window so Kotlin LSP picks it up.")
else:
    print("Reload the window so Kotlin LSP picks it up.")
PY
