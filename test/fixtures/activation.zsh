#!/bin/zsh
# Mirrors a chained-state script: values from the request feed the decrypt.
k=${k:-key-$RANDOM}
iv=${iv:-iv-1}
res=$(print -r -- "cipher:$k:$iv")

parts=(${(s.:.)res})
print -r -- "plain ${parts[2]} ${parts[3]}"
