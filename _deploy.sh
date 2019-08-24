#!/bin/bash
# D language compiler with options
export dopts="-O -release -inline -boundscheck=off"
export dc="dmd ${dopts}"

echo Compiling...
${dc} maps.d || exit 1
${dc} pretty.d || exit 1
${dc} extract_token.d || exit 1
${dc} generate-map-css.d || exit 1
pushd mainnet || exit 1
${dc} rent-price.d || exit 1
popd || exit 1
pushd earnings || exit 1
${dc} update-logs.d || exit 1
${dc} earnings-all.d transaction.d || exit 1
popd || exit 1

echo Building...
./generate-map-css || exit 1
cp map.css public_html/maps || exit 1
cp map.css public_html/testnet/maps || exit 1
