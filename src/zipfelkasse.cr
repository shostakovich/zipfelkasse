# Zipfelkasse – share expenses within a group (a Spliit port for the home server).
#
# Subcommands:
#
#     zipfelkasse [serve]      starts the server (default)
#     zipfelkasse healthcheck  checks GET /healthz of the running server (exit code 0/1)
require "./zipfelkasse/all"

exit Zipfelkasse::CLI.run(ARGV)
