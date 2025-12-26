#!/usr/bin/env bash


BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
cp -r $BASE_DIR/etc/my.cnf /etc/my.cnf

# 这只是个执行实例，请自行根据实际环境修改
