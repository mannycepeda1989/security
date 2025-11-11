FROM node:22.21.1-alpine

ARG APP_DIR=/usr/app
ARG NPMAccessToken

WORKDIR $APP_DIR

RUN echo "//registry.npmjs.org/:_authToken=$NPMAccessToken" > ./.npmrc

COPY package*.json $APP_DIR/

RUN npm ci && rm -f .npmrc

COPY src $APP_DIR/src
