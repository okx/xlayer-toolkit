docker logs -f op-seq | grep -iE "Received forkchoice update" | awk '{
    match($0, /unsafe=[^:]+:([0-9]+)/, unsafe_arr)
    # 从 unsafe 匹配位置之后开始匹配 safe
    rest = substr($0, RSTART + RLENGTH)
    match(rest, /safe=[^:]+:([0-9]+)/, safe_arr)
    unsafe_dec = unsafe_arr[1]
    safe_dec = safe_arr[1]
    diff = unsafe_dec - safe_dec
    printf "%s unsafe=%s safe=%s diff=%s\n", $1, unsafe_dec, safe_dec, diff
}' 