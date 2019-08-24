#!/bin/bash
export DFUSETOKEN=`cat ../dfuse.token`
curl --get \
     -H "Authorization: Bearer $DFUSETOKEN" \
     --data-urlencode "account=prospectorsc" \
     --data-urlencode "scope=prospectorsc" \
     --data-urlencode "table=$1" \
     --data-urlencode "json=true" \
     --data-urlencode "with_block_num=true" \
     --compressed \
     "https://jungle.eos.dfuse.io/v0/state/table" \
     | ../pretty \
     > $1.json
