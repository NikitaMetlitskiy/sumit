# Audit verification notes — 2026-09-09

Snapshot: 2022499. All network probes were read-only or an unauthenticated empty parse request. No production records were written and no paid model request was made.

## Live observations

- GitHub repository API: private=false, default_branch=main, pushed_at=2026-05-19T17:49:43Z, open_issues_count=0, license=null.
- GitHub Actions API: total_count=0. Releases API: empty list.
- GET https://sumit-puce.vercel.app/api/health: HTTP 200, service=sumit-backend, time=2026-09-09T13:36:14.389Z; env flags supabase=true, openai=true, storekit=false.
- POST https://sumit-puce.vercel.app/api/parse with JSON {} and no Authorization: HTTP 401, error=missing_token.
- GET https://mjhosrblavjdxirayvqt.supabase.co/auth/v1/.well-known/jwks.json: URL error before HTTP, hostname not found.
- `dig mjhosrblavjdxirayvqt.supabase.co A +noall +answer +comments`: NXDOMAIN, zero answers.
- `dig @1.1.1.1 mjhosrblavjdxirayvqt.supabase.co A +noall +answer +comments`: NXDOMAIN, zero answers.

## Local checks

- Node v26.8.1: `node --check` passed for all nine checked-in backend JS modules. Not a dependency-resolution or production build test.
- `plutil -lint SumIt.xcodeproj/project.pbxproj`: OK.
- Actual backend modules were executed with synthetic dependencies by backend-reproductions.mjs. Assertions succeeded; output is in backend-results.txt.
- Translation dictionary: 246 entries, 194 distinct literal L() keys used, no literal key absent. This is not a language-quality or exhaustive dynamic-key test.
- Heuristic scan: 109 unique blobs across available Git history. No PEM private-key body, long OpenAI-style key, or service_role JWT match. JWTs detected were anon. No token values were emitted. This is not a comprehensive security guarantee.
- Supplied Apple private key: OpenSSL check returned `Key is valid`; permissions 0600. The key was not used to access Apple, Vercel or Supabase.

## Blocked checks

`xcodebuild -version`:

```text
xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance
```

`xcrun simctl list devices booted`:

```text
xcrun: error: unable to find utility "simctl", not a developer tool or in PATH
```

Both prepared Swift scripts failed before execution. The compiler reported a redefinition of SwiftBridging and a Foundation/CoreFoundation SDK mismatch: installed compiler swiftlang-6.0.3.1.10 versus SDK swiftlang-6.0.3.1.5. Therefore the Swift scripts provide reproduction instructions, not successful runtime evidence. The Keychain diagnostic performed no writes because compilation failed.

The environment was not modified to repair developer tools. No full application build, iOS simulator, authenticated end-to-end parsing, database policy verification, live Apple login or subscription test was completed.
