# Minikube Deployment

> **Important:** Minikube requires a working container driver. On Windows, the easiest is Docker Desktop. Before starting Minikube, ensure Docker Desktop is running. If you see driver errors, start Docker Desktop and then run `minikube start --driver=docker`.

This folder contains Kubernetes manifests for running both SOB services on Minikube.

## Manifests

- `namespace.yaml`: creates namespace `sob`
- `client-deployment.yaml` and `client-service.yaml`: public app on port 3000
- `author-deployment.yaml` and `author-service.yaml`: admin app on port 3001
- `client-secret.example.yaml` and `author-secret.example.yaml`: environment variable templates

## 1) Start Minikube

```powershell
minikube start --driver=docker
```

## 2) Build images inside Minikube Docker

```powershell
minikube -p minikube docker-env --shell powershell | Invoke-Expression
docker build -t sob-client:local ./client
docker build -t sob-author:local ./author
```

## 3) Create runtime secrets

Copy and edit templates with your real values:

```powershell
Copy-Item .\k8s\client-secret.example.yaml .\k8s\client-secret.yaml
Copy-Item .\k8s\author-secret.example.yaml .\k8s\author-secret.yaml
```

Apply them:

```powershell
kubectl apply -f .\k8s\client-secret.yaml
kubectl apply -f .\k8s\author-secret.yaml
```

## 4) Deploy apps

```powershell
kubectl apply -k .\k8s
kubectl get pods -n sob
kubectl get svc -n sob
```

## 5) Access apps

Open each service in your browser:

```powershell
minikube service sob-client -n sob --url
minikube service sob-author -n sob --url
```

## Update after code changes

Rebuild image and restart rollout:

```powershell
docker build -t sob-client:local ./client
kubectl rollout restart deployment/sob-client -n sob

docker build -t sob-author:local ./author
kubectl rollout restart deployment/sob-author -n sob
```
