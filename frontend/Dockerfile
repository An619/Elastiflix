FROM node:26-alpine

WORKDIR /app

COPY package*.json ./

# Install dependencies (single layer, per hadolint DL3059)
RUN npm ci --legacy-peer-deps

COPY . .

# Expose port 3000
EXPOSE 3000

# Start the application
CMD ["npm", "run", "start"]
