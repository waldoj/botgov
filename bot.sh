#!/usr/bin/env bash

# Shared library: credentials, logging, the failure path, and Mastodon
# transport. See lib/botlib/ and the bot-harness docs.
. "$(dirname "$0")/lib/botlib/core.sh"
. "$(dirname "$0")/lib/botlib/secrets.sh"
. "$(dirname "$0")/lib/botlib/mastodon.sh"

# Move into the directory where this script is found
cd "$(dirname "$0")" || exit

load_secrets botgov
require_secrets MASTODON_SERVER MASTODON_TOKEN

# Reduce the raw file to a raw list of sorted domains
function prune_file {
    # Reduce the file to just the list of domains and sort it.
    #
    # The header row is dropped rather than sorted along with the data: it was
    # otherwise posted as though it were a domain, appearing as `"domain` when
    # the header was quoted and `domain` now that it is not.
    grep -v '^"\{0,1\}Domain name' domains.csv \
        | sort | cut -d "," -f 1 > domains-sorted.csv

    # Swap files so we just have the sorted list
    mv -f domains-sorted.csv domains.csv
}

# Retrieve domain list from GitHub
curl --silent -o domains.csv https://raw.githubusercontent.com/cisagov/dotgov-data/main/current-full.csv
RESULT=$?
if [ "$RESULT" -ne 0 ]; then
    echo "Could not retrieve list from GitHub"
    exit 1
fi

if [ ! -f domains-prior.csv ]; then
    echo "There is no prior list to make a comparison"
    prune_file
    mv -f domains.csv domains-prior.csv
    exit 1
fi

# Run the file-pruning function
prune_file

# See if the file is any different than the prior one
CURRENT_HASH=$(md5sum domains.csv |cut -d " " -f 1)
PRIOR_HASH=$(md5sum domains-prior.csv |cut -d " " -f 1)

if [ "$CURRENT_HASH" = "$PRIOR_HASH" ]; then
    echo "File has not changed"
    rm -f domains.csv
    exit 1
fi

# We need to prune again, but I'm not sure why! Without this, each sort is slightly different
prune_file

# Create a new list of new domain names
DOMAIN_LIST=$(diff domains-prior.csv domains.csv |grep ">" |cut -d " " -f 2 |tr '[:upper:]' '[:lower:]')

# If our list is empty, or too brief to be plausible, exit
if [ ${#DOMAIN_LIST} -lt 5 ]; then
    exit 0
fi

# Turn the list into a post.
POST_TEXT="The following .gov domains have been registered in the past 24 hours:
$DOMAIN_LIST"

# Refuse to post something implausibly large.
#
# Mastodon's limit is 500 characters, and a normal day yields a couple of
# dozen domains. A list far beyond that means the comparison went wrong rather
# than that the registry had a busy day -- which is exactly what happened when
# domains-prior.csv was left as the raw seven-column CSV while domains.csv had
# been pruned to one column: diff matched almost nothing, and the bot tried to
# post all 791 domains including ones registered decades ago.
#
# Stopping here leaves domains-prior.csv untouched, so the run can be retried
# once the baseline is fixed.
MASTODON_MAX_CHARS=500

if [ "${#POST_TEXT}" -gt "$MASTODON_MAX_CHARS" ]; then
    exit_error "Post is ${#POST_TEXT} characters, over the ${MASTODON_MAX_CHARS} limit ($(printf '%s\n' "$DOMAIN_LIST" | wc -l | tr -d ' ') domains). Check that domains-prior.csv is a pruned single-column list."
fi

# Send the message to Mastodon.
#
# This used to call curl directly without -f, which meant a 500 from the server
# exited 0: the failure branch below never ran, and a failed post was reported
# as a success. masto_post_status uses -f, so the error is now caught.
masto_post_status "$POST_TEXT" > /dev/null \
    || exit_error "Posting message to Mastodon failed"

log_info "posted to mastodon domains=$(printf '%s' "$DOMAIN_LIST" | wc -l | tr -d ' ')"

rm -f domains-prior.csv
mv -f domains.csv domains-prior.csv
