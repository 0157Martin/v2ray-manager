# Manager source modules

The numbered shell files in this directory are the maintained source of the
manager. Their lexical order is the build order. Run `bash tools/build.sh`
after editing them; deployment and compatibility continue to use the generated
single file `v2ray.sh`.

CI runs `bash tools/build.sh --check` so the generated file cannot drift from
the modules.
