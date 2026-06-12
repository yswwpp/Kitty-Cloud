# 工作流程

本文档记录项目开发过程中的最佳实践和工作流程规范。

---

## Skill 优先原则

**规则**：执行任务前必须先检查相关 skill，不要手动执行。

**原因**：
- 项目提供了很多专门的 skill（如 dev-env-test、get-token、project-mem 等），它们封装了最佳实践和完整流程
- 手动执行容易遗漏步骤、违反规范（比如测试后忘记关闭服务）
- skill 已经包含了自动化、错误处理等完善的机制

**应用场景**：
- 测试本地服务 → 使用 `dev-env-test` skill
- 获取 Token → 使用 `get-token` skill
- 保存记忆 → 使用 `project-mem` skill
- 同步接口文档 → 使用 `sync-apifox` skill

**示例**：
```
❌ 错误做法：
- 手动启动服务
- 手动获取 Token
- 手动测试接口
- 忘记关闭服务

✅ 正确做法：
使用 /dev-env-test skill，它会自动：
- 调整 Nacos 权重
- 获取 Token
- 测试接口
- 提醒关闭服务
```

**日期**：2026-04-25
