# 测试说明

## 测试边界

KOReader 的菜单、触摸手势、排版和真实网络环境必须在 Kindle、Android 或 Linux KOReader 上验收。本仓库自动测试覆盖纯 Lua 逻辑和可注入的请求解析，不替代真机测试。

## 本机运行

```bash
# 推荐：使用仓库脚本准备 lupa（若本机 Python/wheel 匹配）
python3 scripts/bootstrap_pylibs.py
python3 tests/run_tests.py
python3 tests/run_tests.py --strict --stub-log

# 有原生 Lua 5.1 或 LuaJIT 时
python3 tests/run_tests.py --native --lua lua5.1
```

当前测试基座使用 Lua 5.1 兼容语义。若当前 Python 环境没有 `lupa.luajit21`，测试脚本会明确退出并提示原因；这不代表插件运行时失败。

## 当前用例

| 文件 | 覆盖 |
| --- | --- |
| `harness_spec.lua` | 测试基座、文件系统替身、网络替身和日志收集 |
| `cookie_spec.lua` | Cookie 解析、Set-Cookie 合并和 cURL 粘贴 |
| `cm_spec.lua` | CM 握手、bignum 和正文解密向量 |
| `official_api_spec.lua` | 官方 App 请求组装、签名、响应解密和正文清洗 |
| `sign_crypto_spec.lua` | AES、SHA、MD5、Ladon 和请求签名 |
| `sign_extra_spec.lua` | SM3、Simon、AES 和 X-Argus 向量 |
| `logging_spec.lua` | 防止 Cookie、Token 和原始载荷进入日志 |

## 打包验收

```bash
python3 scripts/package.py
unzip -Z1 dist/fanqie.koplugin-v0.0.2.zip
```

脚本会检查顶层目录、`_meta.lua`、`main.lua`、CRC，以及 `config.lua`、`config.local.lua`、`fanqie_device.json`、`.DS_Store` 和 `.luac` 不会进入发布包。

## 真机验收清单

1. 将 zip 解压到 `koreader/plugins/`，确认最终路径为 `plugins/fanqie.koplugin/main.lua`。
2. 打开「番茄小说」并扫码登录。
3. 确认官方 App 源和番茄 API 备用源均处于启用状态。
4. 打开一本书，验证当前章节正文完整；关闭官方 App 源后再次验证备用源。
5. 在设置中分别选择 `3`、`5`、`10` 章，确认后台预下载数量随选择变化。
6. 开启段评，重新获取未缓存章节，确认段评数量和评论详情可用。
7. 检查失败场景不会删除已有章节缓存，也不会把 `fanqie_device.json` 放进发布包。
