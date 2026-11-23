## Summary

What does this PR change and why?

## Testing

Paste the output of the full verification run:

```
test_dir="$(mktemp -d)"
xcrun swiftc Discord.swift Directory.swift MCP.swift Tests/main.swift -o "$test_dir/remote-team-tests"
"$test_dir/remote-team-tests"
./build.sh
codesign --verify --strict "build/Remote Team.app"
lipo -archs "build/Remote Team.app/Contents/MacOS/TeamCheckin"
```

## Checklist

- [ ] All tests pass
- [ ] Build output is `arm64`
- [ ] `AGENTS.md` updated if behaviour, architecture or release steps changed
- [ ] No real credentials, channel IDs or message content included
