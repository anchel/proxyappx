# ProxyAppX 构建入口。运行 `make` 或 `make help` 查看所有命令。
#
# 常用流程
#   日常开发：make install          签名构建并安装到 /Applications
#   提交前：  make check            不签名编译 + 运行测试
#   发布：    修改 project.yml 的 MARKETING_VERSION，写好 docs/release-notes/v<版本>.md，提交并推送，
#             然后 make release && make publish

SHELL := /bin/zsh
.DEFAULT_GOAL := help

VERSION := $(shell sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"]+)"?.*/\1/p' project.yml | head -1)
CONFIG ?= Debug
export CONFIG

.PHONY: help version project build install check test release dmg publish clean

help: ## 显示所有命令
	@echo "ProxyAppX $(VERSION)"
	@awk 'BEGIN {FS = ":.*## "} /^[a-z]+:.*## / {printf "  make %-9s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

version: ## 显示当前版本号
	@echo $(VERSION)

project: ## 用 XcodeGen 生成 ProxyAppX.xcodeproj
	xcodegen generate

build: ## 签名构建（CONFIG=Debug|Release，默认 Debug），不安装
	scripts/build.sh build

install: ## 签名构建并安装到 /Applications，然后打开
	scripts/build.sh install

check: ## 不签名编译检查，并运行核心库测试
	scripts/build.sh check

test: ## 只运行核心库测试
	cd Packages/ProxyAppXCore && swift test

release: ## Release 归档 → Developer ID 导出 → Apple 公证 → 打包 DMG
	scripts/release.sh

dmg: ## 用已公证的 App 重新打包、签名并公证 DMG（不重新构建）
	scripts/make-dmg.sh build/release/notarized/ProxyAppX.app $(VERSION)

publish: ## 打 v<版本> 标签并发布 Release；已发布的版本则替换 DMG
	scripts/publish.sh $(VERSION)

clean: ## 删除构建产物和生成的工程
	rm -rf build ProxyAppX.xcodeproj Packages/ProxyAppXCore/.build
