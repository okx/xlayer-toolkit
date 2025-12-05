# Replayor

replayor in xlayer.

summary container function:
1. init node from genesis
2. unwind to specific blocknumber
3. start  reth
4. start replayor

# init node(optional)
```
cp reth.docker.env.example reth.docker.env
# configure your reth.docker.env
# mainly genesis.json rollup.json path need to configured
docker compose up node-init 
```

# start node reth 
```
# need to build op-reth:lastest images by using devnet script
# if need
cp reth.docker.env.example reth.docker.env
docker compose up -d node
```

# start replayor
```
cp replayor.docker.env.example replayor.docker.env
docker compose up -d replayor
```

# unwind(optional)

```
# stop the node
# configure reth.docker.env 
# mainly UNWIND_TO_BLOCK, for example UNWIND_TO_BLOCK=8596000
docker compose up node-unwind
```