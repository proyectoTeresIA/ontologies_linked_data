#!/bin/bash
# sample script to run unit tests with docker
#
# Usage:
#   ./run-unit-tests.sh                # runs all tests
#   ./run-unit-tests.sh -f path/to/test_file.rb   # runs a single test file

## Parse args
TEST_FILE=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		-f|--file)
			if [[ -n "$2" ]]; then
				TEST_FILE="$2"
				shift 2
			else
				echo "ERROR: -f|--file requires a file path argument" >&2
				exit 1
			fi
			;;
		-h|--help)
			sed -n '2,12p' "$0"
			exit 0
			;;
		--)
			shift
			break
			;;
		*)
			# ignore unknown args for now
			shift
			;;
	esac
done

#DC='docker-compose --profile 4store'
DC='docker compose'

# unit test expects config file even though all settings are set via env vars.
[ -f config/config.rb ] || cp config/config.test.rb config/config.rb

# generate solr configsets for solr container
test/solr/generate_ncbo_configsets.sh

# build docker containers
#$DC run --rm ruby bundle exec rake test TESTOPTS='-v'

# run unit test with AG backend (optionally a single test file)
RUN_ENV=()
if [[ -n "$TEST_FILE" ]]; then
	echo "Running single test file: $TEST_FILE"
	RUN_ENV+=( -e TEST="$TEST_FILE" )
fi

# Forward debug flag when set
if [[ -n "$DEBUG_ONTOLEX" ]]; then
	RUN_ENV+=( -e DEBUG_ONTOLEX="$DEBUG_ONTOLEX" )
fi

$DC run --rm "${RUN_ENV[@]}" ruby-agraph bundle exec rake test TESTOPTS='-v'

$DC --profile agraph --profile 4store stop
