# Caddy Manager Series

[English](#english) | [中文](#中文)

🚀 A powerful, user-friendly shell script collection for managing Caddy web server. Available in three editions: Base, Pro, and Pro Max, providing features from basic management to enterprise-level deployment.

一套功能强大、使用便捷的 Caddy 网页服务器管理脚本集合。提供基础版、专业版和旗舰版三个版本，功能覆盖从基础管理到企业级部署的各种需求。

### ✨ Key Features | 核心特性

- 🔧 Easy installation and configuration | 便捷的安装配置
- 📜 Certificate management | 证书管理
- 🔄 Service control | 服务控制
- 📊 Performance monitoring | 性能监控
- 🐳 Docker support (Pro/Pro Max) | Docker 支持（专业版/旗舰版）
- 🌏 Multi-language (Pro/Pro Max) | 多语言支持（专业版/旗舰版）
- ⚡ Advanced monitoring & alerting (Pro Max) | 高级监控告警（旗舰版）

### 🎯 Perfect For | 适用场景

- Personal websites | 个人网站
- Small to medium businesses | 中小企业
- DevOps teams | 运维团队
- Enterprise deployments | 企业部署

### 💡 Choose Your Edition | 选择合适的版本

- Base: Essential features for daily operations | 基础功能满足日常操作
- Pro: Advanced features for professional users | 进阶功能适合专业用户
- Pro Max: Enterprise-grade features for complete control | 企业级功能实现全面管理

# English

## Introduction

Caddy Manager Series is a collection of shell scripts designed to simplify Caddy web server management. Available in three editions to meet different needs.

## Editions

### Caddy Manager
The essential edition with core features for daily operations.
- Basic installation and configuration
- Service management
- Certificate handling
- Simple monitoring

### Caddy Manager Pro
Advanced edition with enhanced features for professional users.
- All features from Caddy Manager
- Docker integration
- Multi-language support
- Enhanced backup system
- Advanced monitoring

### Caddy Manager Pro Max
Ultimate edition with comprehensive features for enterprise-grade deployment.
- All features from Caddy Manager Pro
- Complete monitoring & alerting system
- Advanced log analysis
- Performance optimization
- Multi-channel alerts (Telegram, DingTalk, Slack)
- Detailed system maintenance

## System Requirements

- Operating System: Ubuntu/Debian/CentOS/RHEL/Fedora
- Required Software:
  - bash
  - curl
  - wget
  - git (for source installation)
  - systemd

## Installation

1. Download the script:
```bash
wget https://raw.githubusercontent.com/raylenzed/caddy-manager/main/caddy-manager-[edition].sh
```

2. Make it executable:
```bash
chmod +x caddy-manager-[edition].sh
```

3. Run the script:
```bash
sudo ./caddy-manager-[edition].sh
```

## Features Comparison

| Feature                    | Manager | Pro | Pro Max |
|---------------------------|---------|-----|----------|
| Basic Installation        | ✓       | ✓   | ✓        |
| Configuration Management  | ✓       | ✓   | ✓        |
| Service Control          | ✓       | ✓   | ✓        |
| Certificate Management   | ✓       | ✓   | ✓        |
| Docker Support           | -       | ✓   | ✓        |
| Multi-language Support   | -       | ✓   | ✓        |
| Advanced Monitoring      | -       | -   | ✓        |
| Alert System             | -       | -   | ✓        |
| Log Analysis             | Basic   | Advanced | Comprehensive |

---

# 中文

## 简介

Caddy Manager 系列是一组用于简化 Caddy 网页服务器管理的 Shell 脚本。提供三个版本以满足不同需求。

## 版本说明

### Caddy Manager
基础版本，提供核心功能，满足日常操作需求。
- 基础安装和配置
- 服务管理
- 证书处理
- 简单监控

### Caddy Manager Pro
进阶版本，为专业用户提供增强功能。
- 包含基础版全部功能
- Docker 集成
- 多语言支持
- 增强的备份系统
- 高级监控

### Caddy Manager Pro Max
旗舰版本，提供企业级部署所需的全面功能。
- 包含进阶版全部功能
- 完整的监控告警系统
- 高级日志分析
- 性能优化
- 多渠道告警（Telegram、钉钉、Slack）
- 详细的系统维护

## 系统要求

- 操作系统：Ubuntu/Debian/CentOS/RHEL/Fedora
- 所需软件：
  - bash
  - curl
  - wget
  - git（源码安装需要）
  - systemd

## 安装使用

1. 下载脚本：
```bash
wget https://raw.githubusercontent.com/raylenzed/caddy-manager/main/caddy-manager-[版本].sh
```

2. 添加执行权限：
```bash
chmod +x caddy-manager-[版本].sh
```

3. 运行脚本：
```bash
sudo ./caddy-manager-[版本].sh
```

## 功能对比

| 功能                | Manager | Pro | Pro Max |
|-------------------|---------|-----|----------|
| 基础安装           | ✓       | ✓   | ✓        |
| 配置管理           | ✓       | ✓   | ✓        |
| 服务控制           | ✓       | ✓   | ✓        |
| 证书管理           | ✓       | ✓   | ✓        |
| Docker 支持       | -       | ✓   | ✓        |
| 多语言支持         | -       | ✓   | ✓        |
| 高级监控           | -       | -   | ✓        |
| 告警系统           | -       | -   | ✓        |
| 日志分析          | 基础    | 高级 | 全面      |
