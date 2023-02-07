#!/usr/bin/env bash

# URL of your Mastodon server, without a trailing slash
MASTODON_SERVER="https://botsin.space"

# Your Mastodon account's access token
MASTODON_TOKEN="ABCDefgh123456789x0x0x0x0x0x0x0x0x0x0x0"

# Reduce the raw file to a raw list of sorted domains
function prune_file {
    # Reduce the file to just the list of domains and sort it
    sort domains.csv |cut -d "," -f 1 > domains-sorted.csv

    # Swap files so we just have the sorted list
    mv -f domains-sorted.csv domains.csv
}

# Move into the directory where this script is found
cd "$(dirname "$0")" || exit

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

# See if the file is any different than the prior one
CURRENT_HASH=$(md5sum domains.csv |cut -d " " -f 1)
PRIOR_HASH=$(md5sum domains-prior.csv |cut -d " " -f 1)

if [ "$CURRENT_HASH" = "$PRIOR_HASH" ]; then
    echo "File has not changed"
    rm -f domains.csv
    exit 1
fi

# Run the file-pruning function
prune_file

# Create a new list of new domain names
DOMAIN_LIST=$(diff domains-prior.csv domains.csv |grep ">" |cut -d " " -f 2 |tr '[:upper:]' '[:lower:]')

# Turn the list into a post.
POST_TEXT="The following .gov domains have been registered in the past 24 hours: $DOMAIN_LIST"

# Send the message to Mastodon
curl "$MASTODON_SERVER"/api/v1/statuses -H "Authorization: Bearer ${MASTODON_TOKEN}" -F "status=\"${POST_TEXT}\""

RESULT=$?
if [ "$RESULT" -ne 0 ]; then
    exit_error "Posting message to Mastodon failed"
fi

rm -f domains-prior.csv
mv -f domains.csv domains-prior.csv
