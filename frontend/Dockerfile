FROM node:22-alpine

WORKDIR /app

COPY package*.json ./

# Install deps and refresh browserslist db in one layer (DL3059)
RUN npm ci --legacy-peer-deps && npx update-browserslist-db@1.4.0

COPY . .

# Expose port 3000
EXPOSE 3000

# Start the application
CMD ["npm", "run", "start"]
