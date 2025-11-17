#!/bin/bash

echo "=== Optimism dev accounts ==="
echo "mnemonic: test test test test test test test test test test test junk"
echo ""

for i in {0..29}; do
    echo "path $i: m/44'/60'/0'/0/$i"

    private_key=$(cast wallet private-key --mnemonic "test test test test test test test test test test test junk" --mnemonic-derivation-path "m/44'/60'/0'/0/$i")

    address=$(cast wallet address --private-key "$private_key")

    echo "address:  $address"
    echo "private key:  $private_key"
    echo "---"
done
