#!/usr/bin/env bash
# @setup
greet() { echo "hello $1"; }
# @end

export NAME=world
greet "$NAME"
ls /nope
echo "line one"
echo "line two"

for i in 1 2 3; do
  echo "tick $i"; sleep 2
done; echo "never printed"
