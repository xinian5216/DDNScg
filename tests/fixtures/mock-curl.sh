#!/usr/bin/env bash

set -u

family="auto"
method="GET"
output_file=""
payload=""
url=""
record_type=""

while (($#)); do
  case "$1" in
    -4 | -6) family="${1#-}" ;;
    --request)
      shift
      method="$1"
      ;;
    --output)
      shift
      output_file="$1"
      ;;
    --write-out | --header | --connect-timeout | --max-time | --retry)
      shift
      ;;
    --data)
      shift
      payload="$1"
      ;;
    --data-urlencode)
      shift
      case "$1" in type=*) record_type="${1#type=}" ;; esac
      ;;
    --*) ;;
    http*) url="$1" ;;
  esac
  shift
done

if [[ "$url" == *'/cdn-cgi/trace' ]]; then
  if [[ "${MOCK_STACK:-dual}" == "v6" && "$family" == "4" ]]; then exit 7; fi
  if [[ "${MOCK_STACK:-dual}" == "v4" && "$family" == "6" ]]; then exit 7; fi
  if [[ "$family" == "4" ]]; then
    printf 'fl=mock\nip=198.51.100.42\n'
  else
    printf 'fl=mock\nip=2001:db8:1::42\n'
  fi
  exit 0
fi

body='{"success":true,"result":{}}'
if [[ "$method" == "GET" && "$url" == *'/dns_records' ]]; then
  if [[ "$record_type" == "A" ]]; then
    body='{"success":true,"result":[{"id":"record-a","content":"198.51.100.1","ttl":1,"proxied":false}]}'
  else
    body='{"success":true,"result":[{"id":"record-aaaa","content":"2001:db8:1::1","ttl":1,"proxied":false}]}'
  fi
fi

if [[ "$method" == "PATCH" || "$method" == "POST" ]]; then
  printf '%s %s %s\n' "$method" "$url" "$payload" >>"${MOCK_LOG:?}"
fi

if [[ -n "$output_file" ]]; then printf '%s\n' "$body" >"$output_file"; else printf '%s\n' "$body"; fi
printf '200'
