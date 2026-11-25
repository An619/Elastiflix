FROM node:26-alpine

WORKDIR /app

COPY package*.json ./

RUN npm ci

COPY . .

USER node

EXPOSE 17700

CMD ["npm", "run", "dev"]
