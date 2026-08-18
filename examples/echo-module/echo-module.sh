#!/bin/sh
LC_ALL=C
export LC_ALL
exec awk -f ./module_json.awk -f ./echo-module.awk
