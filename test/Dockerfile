# Lua 5.1 (the WoW client's version) with busted and luacheck, for `make test` and `make lint`.
FROM alpine:3.20
RUN apk add --no-cache lua5.1 lua5.1-dev luarocks5.1 build-base git \
 && luarocks-5.1 install busted \
 && luarocks-5.1 install luacheck
WORKDIR /src
