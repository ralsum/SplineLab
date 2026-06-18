# BOOT.md

On gateway startup, use the `message` tool to send the Telegram message `OpenClaw Started`.
Also launch the standalone workspace model usage monitor from `/home/ralsum/.openclaw/workspace/model-usage-monitor/run_monitor.sh` so it refreshes every five minutes and stays separate from the email project.
Also start Spline Lab from `/home/ralsum/.openclaw/workspace/run_vector_viewer.sh` if it is not already running, so the browser can come up with Spline Lab ready for inspection.
After sending it, reply with `NO_REPLY`.
