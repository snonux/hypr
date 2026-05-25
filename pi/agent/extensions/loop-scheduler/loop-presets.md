# Loop presets
# Format: * name: INTERVAL prompt text
# INTERVAL supports: 5s, 10m, 2h, 1d, hourly, daily, every 30 minutes
#
# Examples — uncomment and adjust to taste:
# * health:  5m  check the build status
# * review:  1h  review the last 10 git commits
# * monitor: 10m check if there are any errors in the logs

* tasks: 1m automatically start with the next task with fresh context if the current task completed following the agent-task-management skill.
* proceed: 1m proceed with the next task following agent-task-management if the previous or current task being worked on is completed and committed to git.
* review: 1m review all code changes since the last review and add code review comments using agent-task-management skill. use go-best-practices and solid-principles skills.
* scifi: 1m write a scifi story about the current project or continue writing the story into STORY.md. 
