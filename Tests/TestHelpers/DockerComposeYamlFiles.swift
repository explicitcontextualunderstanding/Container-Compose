//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation

public struct DockerComposeYamlFiles {
    public static let dockerComposeYaml1 = """
version: '3.8'

services:
  wp:
    image: wordpress:fpm-alpine
    environment:
      WORDPRESS_DB_HOST: db
      WORDPRESS_DB_USER: wordpress
      WORDPRESS_DB_PASSWORD: wordpress
      WORDPRESS_DB_NAME: wordpress
    depends_on:
      - db
    volumes:
      - wordpress_data:/var/www/html

  web:
    image: nginx:alpine
    ports:
      - "${TEST_PORT_WORDPRESS:-18080}:8080"
    depends_on:
      - wp
    volumes:
      - wordpress_data:/var/www/html:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro

  db:
    image: mysql:8.0
    environment:
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wordpress
      MYSQL_PASSWORD: wordpress
      MYSQL_ROOT_PASSWORD: rootpassword
    volumes:
      - db_data:/var/lib/mysql

volumes:
  wordpress_data:
  db_data:
"""

    public static let nginxConf = """
upstream php {
    server wp:9000;
}

server {
    listen 8080;
    server_name localhost;
    root /var/www/html;
    index index.php index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    location ~ \\.php$ {
        try_files $uri =404;
        fastcgi_pass php;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }
}
"""

    public static let dockerComposeYaml2 = """
        version: '3.8'
        name: webapp

        services:
          nginx:
            image: nginx:alpine
            ports:
              - "${TEST_PORT_WEB:-18081}:80"
            depends_on:
              - app
            networks:
              - frontend
          
          app:
            image: node:18-alpine
            working_dir: /app
            environment:
              NODE_ENV: production
              DATABASE_URL: postgres://db:5432/myapp
            depends_on:
              - db
              - redis
            networks:
              - frontend
              - backend
          
          db:
            image: postgres:14-alpine
            environment:
              POSTGRES_DB: myapp
              POSTGRES_USER: user
              POSTGRES_PASSWORD: password
            volumes:
              - db-data:/var/lib/postgresql/data
            networks:
              - backend
          
          redis:
            image: redis:alpine
            networks:
              - backend

        volumes:
          db-data:

        networks:
          frontend:
          backend:
        """

    public static let dockerComposeYaml3 = """
        version: '3.8'

        services:
          api:
            image: traefik:v2.10
            ports:
              - "${TEST_PORT_GATEWAY:-18082}:80"
              - "${TEST_PORT_API:-18083}:8080"
            depends_on:
              - auth
              - user
              - order
          
          auth:
            image: auth:latest
            environment:
              JWT_SECRET: secret123
              DATABASE_URL: postgres://db:5432/auth
          
          user:
            image: user:latest
            environment:
              DATABASE_URL: postgres://db:5432/users
          
          order:
            image: order:latest
            environment:
              DATABASE_URL: postgres://db:5432/orders
          
          db:
            image: postgres:14
            environment:
              POSTGRES_PASSWORD: postgres
        """

    public static let dockerComposeYaml4 = """
        version: '3.8'

        services:
          app:
            build:
              context: .
              dockerfile: Dockerfile.dev
            volumes:
              - ./app:/app
              - /app/node_modules
            environment:
              NODE_ENV: development
            ports:
              - "${TEST_PORT_APP:-13000}:3000"
            command: npm run dev
        """

    public static let dockerComposeYaml5 = """
        version: '3.8'

        services:
          app:
            image: myapp:latest
            configs:
              - source: app_config
                target: /etc/app/config.yml
            secrets:
              - db_password

        configs:
          app_config:
            external: true

        secrets:
          db_password:
            external: true
        """

    public static let dockerComposeYaml6 = """
        version: '3.8'

        services:
          web:
            image: nginx:latest
            restart: unless-stopped
            healthcheck:
              test: ["CMD", "curl", "-f", "http://localhost"]
              interval: 30s
              timeout: 10s
              retries: 3
              start_period: 40s
          
          db:
            image: postgres:14
            restart: always
            healthcheck:
              test: ["CMD-SHELL", "pg_isready -U postgres"]
              interval: 10s
              timeout: 5s
              retries: 5
        """

    public static let dockerComposeYaml7 = """
        version: '3.8'

        services:
          frontend:
            image: frontend:latest
            depends_on:
              - api
          
          api:
            image: api:latest
            depends_on:
              - cache
              - db
          
          cache:
            image: redis:alpine
          
          db:
            image: postgres:14
        """

    public static let dockerComposeYaml8 = """
        version: '3.8'

        services:
          web:
            image: nginx:alpine
            ports:
              - "${TEST_PORT_WEB2:-18084}:80"
            depends_on:
              app:
                condition: service_started

          app:
            image: python:3.12-alpine
            depends_on:
              db:
                condition: service_healthy
            command: python -m http.server 8000
            environment:
              DATABASE_URL: postgres://postgres:postgres@db:5432/appdb

          db:
            image: postgres:14
            healthcheck:
              test: ["CMD-SHELL", "pg_isready -U postgres"]
              interval: 5s
              timeout: 3s
              retries: 5
              start_period: 10s
            environment:
              POSTGRES_DB: appdb
              POSTGRES_USER: postgres
              POSTGRES_PASSWORD: postgres
        """

    public static func dockerComposeYaml9(containerName: String) -> String {
        return """
            version: '3.8'
            services:
              web:
                image: nginx:alpine
                container_name: \(containerName)
            """
    }

    /// Represents a temporary Docker Compose project copied to a temporary location for testing.
    public struct TemporaryProject {
        /// The URL of the temporary docker-compose.yaml file.
        public let url: URL

        /// The base directory containing the temporary docker-compose.yaml file.
        public let base: URL

        /// The project name derived from the temporary directory name.
        public let name: String
    }

    /// Copies the provided Docker Compose YAML content to a temporary location and returns a
    /// TemporaryProject.
    /// - Parameter yaml: The Docker Compose YAML content to copy.
    /// - Returns: A TemporaryProject containing the URL and project name.
    public static func copyYamlToTemporaryLocation(yaml: String) throws -> TemporaryProject {
        let tempLocation = URL.temporaryDirectory.appending(
            path: "Container-Compose_Tests_\(UUID().uuidString)/docker-compose.yaml")
        let tempBase = tempLocation.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        try yaml.write(to: tempLocation, atomically: false, encoding: .utf8)
        let projectName = tempBase.lastPathComponent

        return TemporaryProject(url: tempLocation, base: tempBase, name: projectName)
    }

}
