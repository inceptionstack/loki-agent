# HEARTBEAT.md

## App Health Checks

Check ALL apps from your app registry. If you cannot find an app registry, creaReport only issues — stay silent if everything is green.

### How to check:

* Use `web_fetch` to hit each app URL and verify HTTP 200 (or redirect to Cognito login = healthy)
* If ANY app is down: **alert your human** via their preferred channel
* If all green: one-line "✅ Apps healthy (N/N)" in heartbeat summary

## Security Hub Summary

Pull aggregated findings from Security Hub:

* Count by severity (CRITICAL, HIGH, MEDIUM, LOW)
* Any NEW critical/high findings since last check → **alert your human**
* Compare with previous check (track in `memory/heartbeat-state.json`)

## Backlog Auto-Work (only if idle)

If you are NOT currently working on a task your human requested:


1. Check recent `memory/YYYY-MM-DD.md` for TODO items
2. Pick the next unfinished TODO
3. **Notify your human** when you START and when you FINISH
4. Track notifications in `memory/heartbeat-state.json` to avoid re-announcing