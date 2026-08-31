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
    # Reduce the file to just the list of domains and sort it
    sort domains.csv |cut -d "," -f 1 > domains-sorted.csv

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
