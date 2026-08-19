#!/bin/sh
# Crée le system "wooclap" dans badgekit-api (idempotent : 409 si déjà là)
set -e
BODY='{"slug":"wooclap","name":"Wooclap System","url":"http://localhost:8080"}'
TOKEN=$(docker compose exec -T api node -e "
const jws = require('jws');
const crypto = require('crypto');
const body = process.argv[1];
const hash = crypto.createHash('sha256').update(body).digest('hex');
console.log(jws.sign({header:{typ:'JWT',alg:'HS256'},
  payload:{key:'master',exp:(Date.now()/1000|0)+300,method:'POST',path:'/systems',
           body:{alg:'sha256',hash:hash}},
  secret:process.env.MASTER_SECRET}));
" "$BODY")
curl -s -X POST -H "Authorization: JWT token=\"$TOKEN\"" \
  -H "Content-Type: application/json" -d "$BODY" http://localhost:8080/systems
echo
