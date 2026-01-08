#!/bin/bash

if [ ! -d "contract" ]; then
    git clone git@github.com:Railgun-Privacy/contract.git
    cd contract
    git apply ../0001-add-railgun-demo.patch
else
    cd contract
fi

./run.sh
