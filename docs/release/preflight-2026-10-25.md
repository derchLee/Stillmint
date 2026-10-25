# Stillmint 发布预检（只读dry-run）

运行：

```sh
python3 scripts/check-release-readiness.py --config docs/release/release-config.owner-input.json --app /absolute/Release/Stillmint.app --check-urls
python3 scripts/test-release-readiness.py
```

配置模板所有真实资料刻意为null。复制填写真实final Bundle ID、Team、ASC商品ID、隐私/条款/支持HTTPS与联系人；不放密钥、证书或密码。App产物目录名称可仍为ClearKeep.app，技术module不必为品牌改名。

工具不构建、不签名、不上传、不提交、不写用户媒体；JSON报告输出stdout。缺字段/占位/未编译产物/未公开获取URL均BLOCKED，退出非0。格式合法不证明网站内容合规、账号归属或商标可用。配置检查项全部通过也**不是G4通过**：工具故意不代替分发签名、ASC协议/商品、真机Photos、Sandbox购买退款、大库、无障碍、隐私声明、年龄问卷与出口合规证据，外部门禁固定标待独立核验。此时exit仍非0，不能拿“没报配置错误”宣称可上传。

当前配置缺失是发布阻断，不妨碍继续本地安全实现/测试。当前验证范围与剩余门禁见[验证状态](validation-status-2026-10-25.md)。本工具读取compiled Info.plist的CKSupportURL（对应Xcode CK_SUPPORT_URL）；如未提供正式值，不猜网址，不创建假联系页。

Retention库存：Activity最多200条/12个月，可单独清除；scan checkpoint含本机asset IDs/hash，规则/手动保护持久；压缩operation账本含source/output IDs用于证明；删除journal保留未结算操作与asset IDs，最近一条completed可留至后续journal写入裁剪，不是完成即删除或定时清空，当前文件排除backup；quota用ThisDeviceOnly Keychain，普通清Activity不清额度或安全proofs。撤销Photos权限与清Activity不等于安全删除全部本机账本，隐私政策须分别说明，不承诺无损恢复或卸载一定重置Keychain。

本机测试不应写正式Keychain/交易；默认unit、fixtureUI与真实StoreKit本地轨分开，缺失/skip/失败都如实记录。不要把fixture UI当真实Photos/Sandbox或设备压力验收。
