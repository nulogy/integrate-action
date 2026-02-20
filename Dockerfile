FROM alpine:latest

LABEL version="1.0.0"
LABEL repository="http://github.com/nulogy/packmanager"
LABEL homepage="http://github.com/nulogy/packmanager"
LABEL maintainer="Nulogy Engineering"
LABEL "com.github.actions.name"="Integrate"
LABEL "com.github.actions.description"="Integrate or hotfix a PR on '/integrate' or '/hotfix' comment"
LABEL "com.github.actions.icon"="git-pull-request"
LABEL "com.github.actions.color"="purple"

RUN apk --no-cache add jq bash curl git git-lfs

ADD entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
