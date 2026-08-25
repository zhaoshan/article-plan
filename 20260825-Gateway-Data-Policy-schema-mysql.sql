-- --------------------------------------------
-- Gateway 数据权限（Data Policy / ABAC）- MySQL DDL 初稿
-- 日期：2026-08-25
-- 数据库：MySQL 8.x
--
-- 说明：
-- 1) 本稿与 20260825-Gateway-Tenant-IAM-schema-mysql.sql 配套使用。
-- 2) 本稿只覆盖数据权限，不覆盖功能权限；功能权限仍由纯 RBAC 表承载。
-- 3) 延续当前项目风格：不强依赖物理外键，主要依靠业务唯一键、索引和应用层校验。
-- 4) 设计目标：把“能不能做”与“能看哪些数据”解耦。
-- --------------------------------------------

SET NAMES utf8mb4;

USE `ai_chat_insight`;

-- ============================================================
-- A. 数据策略定义表
-- ============================================================
--
-- 设计意图：
-- - 一条数据策略描述“对什么资源、什么动作、在什么条件下，做怎样的数据约束”。
-- - 条件不直接存 SQL，而存 DSL JSON，由应用层编译成查询条件或脱敏规则。
-- - effect 常见值：
--   - FILTER：行级过滤
--   - MASK：字段脱敏
--   - DENY：直接拒绝
--   - ALLOW：显式放行（通常用于覆盖 deny 规则时按优先级处理）
--
-- condition_dsl_json 示例：
-- {
--   "operator": "AND",
--   "clauses": [
--     {"field": "tenant_id", "op": "EQ", "source": "context.tenantId"},
--     {"field": "region", "op": "IN", "source": "context.attrs.regions"},
--     {"field": "staff_id", "op": "IN", "source": "context.attrs.staff_ids"}
--   ]
-- }
--
-- mask_fields_json 示例：
-- {
--   "rules": [
--     {"field": "phone", "mode": "MOBILE_MASK"},
--     {"field": "customer_name", "mode": "NAME_MASK"}
--   ]
-- }

CREATE TABLE IF NOT EXISTS `gateway_data_policy` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `data_policy_id` CHAR(32) NOT NULL COMMENT '数据策略业务唯一标识',
  `scope_type` VARCHAR(16) NOT NULL COMMENT '作用域类型：PLATFORM/TENANT',
  `scope_id` CHAR(32) NOT NULL COMMENT '作用域标识；scope_type=TENANT 时为 tenant_id，PLATFORM 时可固定为 PLATFORM',
  `policy_code` VARCHAR(64) NOT NULL COMMENT '策略编码；如 conversation.region.filter / dashboard.staff.scope',
  `policy_name` VARCHAR(128) NOT NULL COMMENT '策略名称',
  `policy_description` VARCHAR(512) DEFAULT NULL COMMENT '策略描述',
  `resource_type` VARCHAR(64) NOT NULL COMMENT '资源类型；如 CONVERSATION/TRACE/DASHBOARD_ITEM/AGENT_SESSION',
  `action` VARCHAR(64) NOT NULL COMMENT '动作；如 VIEW/EXPORT/QUERY/DRILLDOWN',
  `effect` VARCHAR(16) NOT NULL DEFAULT 'FILTER' COMMENT '策略效果：FILTER/MASK/DENY/ALLOW',
  `condition_dsl_json` JSON DEFAULT NULL COMMENT '条件 DSL JSON；由应用层编译为 where 条件或访问判断',
  `mask_fields_json` JSON DEFAULT NULL COMMENT '脱敏字段规则 JSON；仅 effect=MASK 时使用',
  `priority` INT NOT NULL DEFAULT 100 COMMENT '策略优先级；数值越小优先级越高',
  `is_builtin` TINYINT NOT NULL DEFAULT 0 COMMENT '是否内置策略：0否 1是',
  `policy_status` VARCHAR(16) NOT NULL DEFAULT 'ACTIVE' COMMENT '策略状态：ACTIVE/DISABLED',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_data_policy_id` (`data_policy_id`),
  UNIQUE KEY `uk_gateway_data_policy_scope_code` (`scope_type`, `scope_id`, `policy_code`),
  KEY `idx_resource_action_status` (`resource_type`, `action`, `policy_status`),
  KEY `idx_scope_type_scope_id` (`scope_type`, `scope_id`),
  KEY `idx_effect_priority` (`effect`, `priority`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='数据权限策略定义表；承载行过滤、字段脱敏与拒绝访问规则';

-- ============================================================
-- B. 数据策略绑定表
-- ============================================================
--
-- 设计意图：
-- - 将数据策略绑定给某个主体。
-- - bind_type 常见值：
--   - ROLE：最常见，按角色获得数据权限
--   - MEMBERSHIP：按租户成员关系细化覆盖
--   - TENANT：租户级全局策略
--
-- 说明：
-- - 绑定表不直接存条件，只存“谁绑定了哪条策略”。
-- - 真正的策略逻辑在 gateway_data_policy.condition_dsl_json 中定义。

CREATE TABLE IF NOT EXISTS `gateway_data_policy_binding` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `data_policy_binding_id` CHAR(32) NOT NULL COMMENT '数据策略绑定业务唯一标识',
  `bind_type` VARCHAR(16) NOT NULL COMMENT '绑定对象类型：ROLE/MEMBERSHIP/TENANT',
  `bind_id` CHAR(32) NOT NULL COMMENT '绑定对象业务ID；如 role_id / membership_id / tenant_id',
  `data_policy_id` CHAR(32) NOT NULL COMMENT '数据策略ID；逻辑关联 gateway_data_policy.data_policy_id',
  `binding_status` VARCHAR(16) NOT NULL DEFAULT 'ACTIVE' COMMENT '绑定状态：ACTIVE/DISABLED',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_data_policy_binding_id` (`data_policy_binding_id`),
  UNIQUE KEY `uk_gateway_data_policy_binding_pair` (`bind_type`, `bind_id`, `data_policy_id`),
  KEY `idx_data_policy_id` (`data_policy_id`),
  KEY `idx_bind_type_bind_id_status` (`bind_type`, `bind_id`, `binding_status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='数据策略绑定表；将策略绑定到角色、成员关系或租户';

-- ============================================================
-- C. 外部 IdP 数据范围映射表
-- ============================================================
--
-- 设计意图：
-- - 把外部 IdP 的 group / claim 映射成“内部数据属性上下文”。
-- - 推荐流程：
--   1) 用户通过 OIDC/SAML 登录
--   2) 从外部 claims / groups 命中本表规则
--   3) 生成 context.attrs（如 regions/team_ids/staff_ids）
--   4) gateway_data_policy.condition_dsl_json 再消费这些 attrs
--
-- attribute_patch_json 示例：
-- {
--   "regions": ["CN", "SG"],
--   "team_ids": ["TEAM_A"],
--   "staff_ids": ["S001", "S002"]
-- }
--
-- target_data_policy_id 使用建议：
-- - 常规场景优先只写 attribute_patch_json，不直接挂策略。
-- - 如确需“命中某个外部 group 后附加一条固定策略”，可填 target_data_policy_id。

CREATE TABLE IF NOT EXISTS `gateway_idp_data_scope_mapping` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `idp_data_scope_mapping_id` CHAR(32) NOT NULL COMMENT '外部数据范围映射业务唯一标识',
  `tenant_idp_config_id` CHAR(32) NOT NULL COMMENT '租户 IdP 配置ID；逻辑关联 gateway_tenant_idp_config.tenant_idp_config_id',
  `source_type` VARCHAR(16) NOT NULL DEFAULT 'GROUP' COMMENT '外部来源类型：GROUP/CLAIM',
  `source_key` VARCHAR(128) NOT NULL COMMENT '外部来源键；GROUP 时可为 groups/roles，CLAIM 时为具体 claim 名',
  `match_mode` VARCHAR(16) NOT NULL DEFAULT 'EXACT' COMMENT '匹配模式：EXACT/REGEX/CONTAINS/IN',
  `match_value` VARCHAR(255) NOT NULL COMMENT '匹配值；如具体 group 名、claim 值或正则表达式',
  `attribute_patch_json` JSON DEFAULT NULL COMMENT '命中后写入内部数据属性上下文的 JSON Patch',
  `target_data_policy_id` CHAR(32) DEFAULT NULL COMMENT '可选：命中后直接附加的数据策略ID；逻辑关联 gateway_data_policy.data_policy_id',
  `priority` INT NOT NULL DEFAULT 100 COMMENT '映射优先级；数值越小优先级越高',
  `mapping_status` VARCHAR(16) NOT NULL DEFAULT 'ACTIVE' COMMENT '映射状态：ACTIVE/DISABLED',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_idp_data_scope_mapping_id` (`idp_data_scope_mapping_id`),
  UNIQUE KEY `uk_gateway_idp_data_scope_rule` (`tenant_idp_config_id`, `source_type`, `source_key`, `match_mode`, `match_value`),
  KEY `idx_target_data_policy_id` (`target_data_policy_id`),
  KEY `idx_mapping_status_priority` (`mapping_status`, `priority`),
  KEY `idx_source_type_source_key` (`source_type`, `source_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='外部 IdP group/claim 到内部数据属性上下文的映射表';

-- ============================================================
-- D. 设计补充说明
-- ============================================================
--
-- 1) 推荐的职责边界
--    - RBAC：决定“能不能做这个动作”
--    - Data Policy：决定“能看哪些数据、哪些字段需要脱敏”
--
-- 2) 推荐的落地路径
--    - 第一步：先落本脚本中的 3 张表，不改业务查询。
--    - 第二步：在 RequestContext 中补一份 data attrs 上下文（如 regions/team_ids/staff_ids）。
--    - 第三步：让 Dashboard / Monitor / Chat History 等查询层消费 gateway_data_policy.condition_dsl_json。
--
-- 3) 推荐的判定顺序（示意）
--    - 先做登录鉴权
--    - 再算角色（RBAC）
--    - 再算 data attrs（IdP 映射）
--    - 最后把 data policy 编译进查询过滤或字段脱敏
--
-- 4) 初期不建议做的事情
--    - 不建议把外部 group 直接映射为原始 SQL 片段
--    - 不建议把数据权限硬编码散落到各业务 Mapper
--
