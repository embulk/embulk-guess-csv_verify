embulk-guess-csv_verify
========================

This is an "experimental" Ruby-based plugin to compare the old Ruby-based CSV guess v.s. the new Java-reimplemented CSV guess. This as a guess plugin returns the result from the old Ruby-based implementation as its own result.

```
exec:
  exclude_guess_plugins: ["csv"]
  guess_plugins: ["csv_verify"]
in:
  type: file
  path_prefix: "..."
```

It dumps config differences between the old Ruby-based CSV guess and the new Java-reimplemented CSV guess. Make sure they include no credential information.
