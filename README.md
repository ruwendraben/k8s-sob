# ShopsOnBoard (SOB)

A multi-service marketplace application with a public client and an admin author service, deployed on Kubernetes via Minikube.

## Project Structure

```
├── client/        # Public timeline & seller frontend (port 3000)
├── author/        # Admin dashboard (port 3001)
├── k8s/           # Kubernetes manifests
├── deploy.ps1     # Full deploy script (Windows)
└── destroy.ps1    # Full teardown script (Windows)
```

## Architecture

| Pod | Role | Port |
|---|---|---|
| `sob-client` | Express app — public facing | 3000 |
| `sob-author` | Express app — admin only | 3001 |
| `redis-session` | Session store for sob-client | 6379 |

Both apps connect to AWS RDS (PostgreSQL), AWS SSM (session secret), and AWS S3 (images).

---

## AWS Prerequisites

Ensure the following AWS resources exist before deploying:

### 1. RDS (PostgreSQL)
- Create a PostgreSQL instance
- Note the hostname, port, database name, user, and password

### 2. S3 Bucket
- Create a bucket for user-uploaded images (e.g. `sob-media`)
- Note the bucket name and region (`eu-west-2`)

### 3. SSM Parameter Store
- Create a `SecureString` parameter for the session secret
- e.g. `/sob/session-secret` with a long random string value
- Note the parameter path

### 4. IAM User
- Create an IAM user with programmatic access
- Attach permissions: `s3:PutObject`, `s3:DeleteObject`, `ssm:GetParameter`
- Note the `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`

---

## Local Deployment (Minikube)

### Prerequisites

- Docker Desktop
- Minikube
- kubectl
- PowerShell (Windows)

> First time only: `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`

### 1. Create secret files

```powershell
Copy-Item .\k8s\client-secret.example.yaml .\k8s\client-secret.yaml
Copy-Item .\k8s\author-secret.example.yaml .\k8s\author-secret.yaml
```

Edit both files and fill in your AWS values (RDS, S3, SSM, IAM credentials).

### 2. Deploy

```powershell
.\deploy.ps1
```

This will:
- Start Minikube (skipped if already running)
- Build both Docker images inside Minikube
- Apply namespace, secrets, and all manifests
- Wait for pods to be ready
- Open port-forward tunnels for both services

**Access:**
- Client: http://localhost:3000
- Author: http://localhost:3001

### 3. Teardown

Full clean teardown (removes all resources and images):
```powershell
.\destroy.ps1
```

Re-deploy after teardown:
```powershell
.\deploy.ps1
```
