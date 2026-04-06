# Loop presets
# Format: * name: INTERVAL prompt text
# INTERVAL supports: 5s, 10m, 2h, 1d, hourly, daily, every 30 minutes
#
# Examples — uncomment and adjust to taste:
# * health:  5m  check the build status
# * review:  1h  review the last 10 git commits
# * monitor: 10m check if there are any errors in the logs

* tasks: 1m automatically start with the next task with fresh context if the current task completed following the agent-task-management skill.
* proceed: 1m proceed
