# fanqie-KOReader 常用任务入口
#
# 本机（Windows）没有原生 Lua，所以 `make test` 会自动挑运行时：
# 有 lua5.1/luajit 就走原生（CI 的 Ubuntu 作业走这条），否则退回 lupa。

LUA    ?= lua5.1
PYTHON ?= python
SPEC   ?=

.DEFAULT_GOAL := help

.PHONY: help test test-native test-windows test-spec test-strict lint package sample verify-sample clean

help: ## 显示本帮助
	@echo "fanqie-KOReader —— 可用目标："
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-14s %s\n", $$1, $$2}'
	@echo
	@echo "变量：LUA=$(LUA)  PYTHON=$(PYTHON)  SPEC=$(SPEC)"

test: ## 跑全部用例（自动选运行时）
	@if command -v $(LUA) >/dev/null 2>&1; then \
		$(MAKE) test-native; \
	else \
		echo "未找到 $(LUA)，改用 Python + lupa"; \
		$(MAKE) test-windows; \
	fi

test-native: ## 用原生 Lua 5.1 跑用例
	$(LUA) tests/run.lua

test-windows: ## 用 Python + lupa（内嵌 LuaJIT 2.1）跑用例
	$(PYTHON) tests/run_tests.py

test-spec: ## 只跑一个用例，例：make test-spec SPEC=cookie
	@test -n "$(SPEC)" || { echo "用法：make test-spec SPEC=cookie"; exit 2; }
	@if command -v $(LUA) >/dev/null 2>&1; then \
		$(LUA) tests/run.lua $(SPEC)_spec; \
	else \
		$(PYTHON) tests/run_tests.py $(SPEC); \
	fi

test-strict: ## 严格模式跑用例：未登记的 KOReader 模块直接报错（守住"纯逻辑不依赖 UI"）
	$(PYTHON) tests/run_tests.py --strict --stub-log

lint: ## luacheck 静态检查（基线未清，不阻塞）
	@if command -v luacheck >/dev/null 2>&1; then luacheck .; else echo "未安装 luacheck，跳过"; fi

package: ## 打出可直接安装的 zip 到 dist/
	$(PYTHON) scripts/package.py

sample: ## 生成示例 EPUB（肉眼验收 EPUB 生成器）
	$(PYTHON) tools/make_sample_epub.py --probe

verify-sample: ## 独立验收 sample-book.epub（Python 标准库，非插件自身实现）
	$(PYTHON) tools/verify_epub.py sample-book.epub --html sample-book.report.html

clean: ## 清掉临时产物（不碰源码与 refs/）
	rm -rf dist tests/.tmp tests/out
