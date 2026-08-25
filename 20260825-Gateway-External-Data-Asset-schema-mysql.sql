-- --------------------------------------------
-- Gateway 外部数据源 / 数据资产接入 - MySQL DDL 初稿
-- 日期：2026-08-25
-- 数据库：MySQL 8.x
--
-- 说明：
-- 1) 本稿与以下脚本配套使用：
--    - 20260825-Gateway-Tenant-IAM-schema-mysql.sql
--    - 20260825-Gateway-Data-Policy-schema-mysql.sql
-- 2) 本稿关注“数据接入与资产管理”，不覆盖功能权限和数据权限策略本身。
-- 3) 延续当前项目风格：不强依赖物理外键，主要依靠业务唯一键、索引和应用层校验。
-- 4) 设计目标：把“外部数据源接入”“平台内可消费的数据资产”“资产级授权”“查询模板”“访问审计”拆开治理。
-- --------------------------------------------

SET NAMES utf8mb4;

USE `ai_chat_insight`;

-- ============================================================
-- A. 外部数据源定义表
-- ============================================================
--
-- 设计意图：
-- - 描述一个可被平台接入的外部数据源。
-- - 推荐只保存非敏感连接元数据；真正密钥建议只存 secret_ref，接入密钥管理系统。
-- - source_type 示例：
--   MYSQL / TIDB / POSTGRESQL / ORACLE / SQLSERVER / HIVE / ELASTICSEARCH / HTTP_API / OBJECT_STORAGE

CREATE TABLE IF NOT EXISTS `gateway_external_data_source` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `external_data_source_id` CHAR(32) NOT NULL COMMENT '外部数据源业务唯一标识',
  `tenant_id` CHAR(32) NOT NULL COMMENT '所属租户ID；逻辑关联 gateway_tenant.tenant_id',
  `source_code` VARCHAR(64) NOT NULL COMMENT '数据源编码；租户内唯一',
  `source_name` VARCHAR(128) NOT NULL COMMENT '数据源名称',
  `source_type` VARCHAR(32) NOT NULL COMMENT '数据源类型：MYSQL/TIDB/POSTGRESQL/ORACLE/HIVE/ELASTICSEARCH/HTTP_API 等',
  `environment_type` VARCHAR(16) NOT NULL DEFAULT 'PROD' COMMENT '环境类型：PROD/UAT/TEST/DEV',
  `ownership_type` VARCHAR(16) NOT NULL DEFAULT 'CUSTOMER_MANAGED' COMMENT '归属方式：CUSTOMER_MANAGED/PLATFORM_MANAGED',
  `connection_mode` VARCHAR(16) NOT NULL DEFAULT 'DIRECT' COMMENT '接入方式：DIRECT/PROXY/SYNC/CDC/WAREHOUSE',
  `auth_mode` VARCHAR(16) NOT NULL DEFAULT 'SECRET_REF' COMMENT '鉴权方式：PASSWORD/AKSK/OAUTH/SECRET_REF/IAM_ROLE',
  `endpoint_uri_masked` VARCHAR(512) DEFAULT NULL COMMENT '脱敏后的连接地址或 endpoint；如 jdbc:mysql://host:3306/db',
  `database_name` VARCHAR(128) DEFAULT NULL COMMENT '默认数据库或 catalog 名称',
  `schema_name` VARCHAR(128) DEFAULT NULL COMMENT '默认 schema 名称；关系型数据库可使用',
  `network_zone` VARCHAR(64) DEFAULT NULL COMMENT '网络区域或网络策略标签；如 private-vpc / customer-vpn',
  `secret_ref` VARCHAR(255) DEFAULT NULL COMMENT '密钥引用；指向外部密钥管理系统中的 secret',
  `connection_config_json` JSON DEFAULT NULL COMMENT '非敏感连接配置 JSON；如超时、SSL、driver、region、headers 模板等',
  `health_status` VARCHAR(16) NOT NULL DEFAULT 'PENDING' COMMENT '健康状态：PENDING/ACTIVE/UNREACHABLE/ERROR/DISABLED',
  `last_verified_at` DATETIME DEFAULT NULL COMMENT '最近一次连通性验证时间',
  `last_sync_at` DATETIME DEFAULT NULL COMMENT '最近一次元数据同步或探活时间',
  `owner_user_id` CHAR(32) DEFAULT NULL COMMENT '平台侧负责人用户ID',
  `remarks` VARCHAR(512) DEFAULT NULL COMMENT '备注说明',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_external_data_source_id` (`external_data_source_id`),
  UNIQUE KEY `uk_gateway_external_data_source_code` (`tenant_id`, `source_code`),
  KEY `idx_source_type_status` (`source_type`, `health_status`),
  KEY `idx_tenant_env` (`tenant_id`, `environment_type`),
  KEY `idx_owner_user_id` (`owner_user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='外部数据源定义表；描述一个客户或平台接入的数据源';

-- ============================================================
-- B. 外部数据资产定义表
-- ============================================================
--
-- 设计意图：
-- - 一条资产代表“平台允许消费的对象”，不一定等于物理原始表。
-- - 推荐优先登记 view、物化表、数据集或受控 API，而不是直接开放生产原始表。
-- - asset_type 示例：
--   TABLE / VIEW / MATERIALIZED_VIEW / DATASET / API / INDEX / FILE_OBJECT

CREATE TABLE IF NOT EXISTS `gateway_external_data_asset` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `external_data_asset_id` CHAR(32) NOT NULL COMMENT '外部数据资产业务唯一标识',
  `tenant_id` CHAR(32) NOT NULL COMMENT '所属租户ID；逻辑关联 gateway_tenant.tenant_id',
  `external_data_source_id` CHAR(32) NOT NULL COMMENT '所属外部数据源ID；逻辑关联 gateway_external_data_source.external_data_source_id',
  `asset_code` VARCHAR(64) NOT NULL COMMENT '资产编码；租户内唯一',
  `asset_name` VARCHAR(128) NOT NULL COMMENT '资产名称',
  `asset_type` VARCHAR(32) NOT NULL COMMENT '资产类型：TABLE/VIEW/MATERIALIZED_VIEW/DATASET/API/INDEX/FILE_OBJECT',
  `schema_name` VARCHAR(128) DEFAULT NULL COMMENT '物理 schema 名称；非关系型或 API 可为空',
  `object_name` VARCHAR(255) DEFAULT NULL COMMENT '物理对象名；如表名、视图名、索引名或 API resource',
  `asset_locator` VARCHAR(1024) DEFAULT NULL COMMENT '统一定位符；如 schema.table、index alias、api path',
  `logical_namespace` VARCHAR(64) DEFAULT NULL COMMENT '逻辑命名空间；如 crm/order/cx_trace',
  `owner_user_id` CHAR(32) DEFAULT NULL COMMENT '平台侧资产负责人用户ID',
  `asset_status` VARCHAR(16) NOT NULL DEFAULT 'DRAFT' COMMENT '资产状态：DRAFT/ACTIVE/DISABLED/ARCHIVED',
  `sensitivity_level` VARCHAR(16) NOT NULL DEFAULT 'L2' COMMENT '敏感等级：L1/L2/L3/L4',
  `contains_pii` TINYINT NOT NULL DEFAULT 0 COMMENT '是否包含个人敏感信息：0否 1是',
  `access_pattern` VARCHAR(16) NOT NULL DEFAULT 'READ_ONLY' COMMENT '访问模式：READ_ONLY/SNAPSHOT/EXPORT_ONLY/QUERY_TEMPLATE_ONLY',
  `row_security_mode` VARCHAR(16) NOT NULL DEFAULT 'PLATFORM_POLICY' COMMENT '行权限模式：NONE/PLATFORM_POLICY/SOURCE_NATIVE/MIXED',
  `field_security_mode` VARCHAR(16) NOT NULL DEFAULT 'PLATFORM_POLICY' COMMENT '字段权限模式：NONE/PLATFORM_POLICY/SOURCE_NATIVE/MIXED',
  `sync_strategy` VARCHAR(16) NOT NULL DEFAULT 'LIVE' COMMENT '同步策略：LIVE/SNAPSHOT/CDC/CACHE',
  `query_hint_json` JSON DEFAULT NULL COMMENT '查询提示 JSON；如默认 where、分区键、排序键、分页字段',
  `metadata_json` JSON DEFAULT NULL COMMENT '扩展元数据 JSON；如业务描述、标签、owner 团队、来源系统等',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_external_data_asset_id` (`external_data_asset_id`),
  UNIQUE KEY `uk_gateway_external_data_asset_code` (`tenant_id`, `asset_code`),
  KEY `idx_source_asset_status` (`external_data_source_id`, `asset_status`),
  KEY `idx_asset_type_status` (`asset_type`, `asset_status`),
  KEY `idx_owner_user_id` (`owner_user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='外部数据资产定义表；代表平台允许消费的数据对象';

-- ============================================================
-- C. 外部数据资产字段目录表
-- ============================================================
--
-- 设计意图：
-- - 维护逻辑字段与物理字段的映射。
-- - Data Policy 中的 condition_dsl_json 推荐引用 logical_field_code，而不是直接写真实列名。
-- - 这样同一套策略可以复用到不同客户的不同底层对象。

CREATE TABLE IF NOT EXISTS `gateway_external_data_asset_field` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `external_data_asset_field_id` CHAR(32) NOT NULL COMMENT '资产字段业务唯一标识',
  `external_data_asset_id` CHAR(32) NOT NULL COMMENT '所属外部数据资产ID；逻辑关联 gateway_external_data_asset.external_data_asset_id',
  `logical_field_code` VARCHAR(64) NOT NULL COMMENT '逻辑字段编码；供策略 DSL、查询模板、上层应用统一引用',
  `logical_field_name` VARCHAR(128) NOT NULL COMMENT '逻辑字段名称',
  `physical_field_name` VARCHAR(255) DEFAULT NULL COMMENT '物理字段名称；关系型表/视图常用',
  `physical_field_path` VARCHAR(512) DEFAULT NULL COMMENT '物理字段路径；适用于 JSON、ES 或 API 响应结构',
  `data_type` VARCHAR(32) NOT NULL COMMENT '字段类型：STRING/INT/LONG/DECIMAL/DATE/DATETIME/BOOLEAN/JSON',
  `sensitivity_level` VARCHAR(16) NOT NULL DEFAULT 'L1' COMMENT '字段敏感等级：L1/L2/L3/L4',
  `is_identifier` TINYINT NOT NULL DEFAULT 0 COMMENT '是否为主标识字段：0否 1是',
  `is_filterable` TINYINT NOT NULL DEFAULT 1 COMMENT '是否允许作为过滤条件：0否 1是',
  `is_sortable` TINYINT NOT NULL DEFAULT 0 COMMENT '是否允许排序：0否 1是',
  `is_maskable` TINYINT NOT NULL DEFAULT 0 COMMENT '是否允许平台侧脱敏：0否 1是',
  `default_mask_mode` VARCHAR(32) DEFAULT NULL COMMENT '默认脱敏模式：NAME_MASK/MOBILE_MASK/EMAIL_MASK/HASH/TRUNCATE',
  `field_status` VARCHAR(16) NOT NULL DEFAULT 'ACTIVE' COMMENT '字段状态：ACTIVE/DISABLED/HIDDEN',
  `metadata_json` JSON DEFAULT NULL COMMENT '字段扩展元数据 JSON；如字典、单位、展示别名、说明等',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_external_data_asset_field_id` (`external_data_asset_field_id`),
  UNIQUE KEY `uk_gateway_external_asset_logical_field` (`external_data_asset_id`, `logical_field_code`),
  KEY `idx_field_status` (`field_status`),
  KEY `idx_physical_field_name` (`physical_field_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='外部数据资产字段目录表；维护逻辑字段与物理字段映射';

-- ============================================================
-- D. 外部数据资产授权表
-- ============================================================
--
-- 设计意图：
-- - 决定“谁可以访问这份数据资产”。
-- - 数据范围过滤不在本表表达，而交由 gateway_data_policy 处理。
-- - access_mode 示例：
--   READ / EXPORT / AGGREGATE_ONLY / QUERY_TEMPLATE_ONLY / API_PROXY_ONLY

CREATE TABLE IF NOT EXISTS `gateway_external_data_asset_grant` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `external_data_asset_grant_id` CHAR(32) NOT NULL COMMENT '资产授权业务唯一标识',
  `external_data_asset_id` CHAR(32) NOT NULL COMMENT '外部数据资产ID；逻辑关联 gateway_external_data_asset.external_data_asset_id',
  `grant_type` VARCHAR(16) NOT NULL COMMENT '授权对象类型：ROLE/MEMBERSHIP/TENANT',
  `grant_target_id` CHAR(32) NOT NULL COMMENT '授权对象业务ID；如 role_id / membership_id / tenant_id',
  `access_mode` VARCHAR(32) NOT NULL DEFAULT 'READ' COMMENT '访问方式：READ/EXPORT/AGGREGATE_ONLY/QUERY_TEMPLATE_ONLY/API_PROXY_ONLY',
  `grant_status` VARCHAR(16) NOT NULL DEFAULT 'ACTIVE' COMMENT '授权状态：ACTIVE/DISABLED',
  `constraint_json` JSON DEFAULT NULL COMMENT '资产级附加约束 JSON；如禁止导出、默认 limit、只允许聚合字段等',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_external_data_asset_grant_id` (`external_data_asset_grant_id`),
  UNIQUE KEY `uk_gateway_external_asset_grant_pair` (`external_data_asset_id`, `grant_type`, `grant_target_id`, `access_mode`),
  KEY `idx_grant_target_status` (`grant_type`, `grant_target_id`, `grant_status`),
  KEY `idx_access_mode` (`access_mode`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='外部数据资产授权表；决定谁有资格使用该资产';

-- ============================================================
-- E. 外部查询模板表
-- ============================================================
--
-- 设计意图：
-- - 避免运行时直接执行任意 SQL / 任意 DSL / 任意 API。
-- - 让平台只执行审核通过的查询模板。
-- - template_type 示例：
--   SQL / ES_DSL / HTTP_REQUEST / STORED_PROCEDURE

CREATE TABLE IF NOT EXISTS `gateway_external_query_template` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `external_query_template_id` CHAR(32) NOT NULL COMMENT '查询模板业务唯一标识',
  `external_data_asset_id` CHAR(32) NOT NULL COMMENT '所属外部数据资产ID；逻辑关联 gateway_external_data_asset.external_data_asset_id',
  `template_code` VARCHAR(64) NOT NULL COMMENT '模板编码；资产内唯一',
  `template_name` VARCHAR(128) NOT NULL COMMENT '模板名称',
  `template_type` VARCHAR(32) NOT NULL COMMENT '模板类型：SQL/ES_DSL/HTTP_REQUEST/STORED_PROCEDURE',
  `execution_mode` VARCHAR(16) NOT NULL DEFAULT 'READ_ONLY' COMMENT '执行模式：READ_ONLY/PAGED/ASYNC_EXPORT',
  `template_body` LONGTEXT NOT NULL COMMENT '模板正文；SQL、ES DSL 或 HTTP request body 模板',
  `parameter_schema_json` JSON DEFAULT NULL COMMENT '参数定义 JSON；描述允许传入的参数、类型、必填项、默认值',
  `parameter_binding_json` JSON DEFAULT NULL COMMENT '参数绑定 JSON；描述模板变量与 logical_field_code 或上下文字段的关系',
  `default_sort_json` JSON DEFAULT NULL COMMENT '默认排序定义 JSON',
  `result_mapping_json` JSON DEFAULT NULL COMMENT '结果字段映射 JSON；可将物理字段映射为上层统一结构',
  `max_row_limit` INT NOT NULL DEFAULT 1000 COMMENT '单次最大返回行数限制',
  `template_status` VARCHAR(16) NOT NULL DEFAULT 'DRAFT' COMMENT '模板状态：DRAFT/ACTIVE/DISABLED',
  `requires_data_policy` TINYINT NOT NULL DEFAULT 1 COMMENT '是否要求套用平台数据策略：0否 1是',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_external_query_template_id` (`external_query_template_id`),
  UNIQUE KEY `uk_gateway_external_query_template_code` (`external_data_asset_id`, `template_code`),
  KEY `idx_template_type_status` (`template_type`, `template_status`),
  KEY `idx_execution_mode` (`execution_mode`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='外部查询模板表；控制只执行被批准的查询模板';

-- ============================================================
-- F. 外部数据访问审计表
-- ============================================================
--
-- 设计意图：
-- - 记录每一次真实的数据访问。
-- - 可用于审计、计费、排障、数据合规追溯。

CREATE TABLE IF NOT EXISTS `gateway_external_data_access_audit_log` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `external_data_access_audit_log_id` CHAR(32) NOT NULL COMMENT '外部数据访问审计业务唯一标识',
  `tenant_id` CHAR(32) NOT NULL COMMENT '租户ID',
  `external_data_source_id` CHAR(32) DEFAULT NULL COMMENT '外部数据源ID',
  `external_data_asset_id` CHAR(32) DEFAULT NULL COMMENT '外部数据资产ID',
  `external_query_template_id` CHAR(32) DEFAULT NULL COMMENT '查询模板ID；若走模板执行则记录',
  `actor_user_id` CHAR(32) DEFAULT NULL COMMENT '操作者用户ID',
  `actor_membership_id` CHAR(32) DEFAULT NULL COMMENT '操作者成员关系ID',
  `access_channel` VARCHAR(16) NOT NULL DEFAULT 'DASHBOARD' COMMENT '访问渠道：DASHBOARD/AGENT/INSIGHT/API/EXPORT/JOB',
  `access_mode` VARCHAR(32) NOT NULL COMMENT '访问方式：READ/EXPORT/AGGREGATE_ONLY/QUERY_TEMPLATE_ONLY/API_PROXY_ONLY',
  `trace_id` VARCHAR(64) DEFAULT NULL COMMENT '链路追踪ID',
  `request_id` VARCHAR(64) DEFAULT NULL COMMENT '请求ID',
  `source_request_id` VARCHAR(128) DEFAULT NULL COMMENT '外部数据源侧 request id 或 query id',
  `request_params_json` JSON DEFAULT NULL COMMENT '请求参数 JSON；建议脱敏后存储',
  `applied_policy_ids_json` JSON DEFAULT NULL COMMENT '本次命中的数据策略ID数组 JSON',
  `applied_scope_attrs_json` JSON DEFAULT NULL COMMENT '本次展开后的数据范围属性 JSON；如 regions/team_ids/staff_ids',
  `result_status` VARCHAR(16) NOT NULL DEFAULT 'SUCCESS' COMMENT '结果状态：SUCCESS/FAILED/DENIED/TIMEOUT',
  `affected_row_count` BIGINT DEFAULT NULL COMMENT '返回或影响的数据行数',
  `duration_ms` BIGINT DEFAULT NULL COMMENT '执行耗时（毫秒）',
  `error_code` VARCHAR(64) DEFAULT NULL COMMENT '错误码',
  `error_message` VARCHAR(512) DEFAULT NULL COMMENT '错误信息摘要',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除；审计表通常不建议物理删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_external_data_access_audit_log_id` (`external_data_access_audit_log_id`),
  KEY `idx_tenant_asset_time` (`tenant_id`, `external_data_asset_id`, `create_time`),
  KEY `idx_actor_user_id` (`actor_user_id`),
  KEY `idx_trace_id` (`trace_id`),
  KEY `idx_result_status` (`result_status`),
  KEY `idx_request_id` (`request_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='外部数据访问审计表';

-- ============================================================
-- G. 设计补充说明
-- ============================================================
--
-- 1) 推荐的接入模式
--    - 优先接 view、集成表、物化表、受控 API
--    - 不建议直接裸连客户生产原始表并开放任意 SQL
--
-- 2) 推荐的权限判定顺序
--    - 先做 RBAC：判断角色是否有资产使用权限
--    - 再做 Data Policy：决定数据范围与字段脱敏
--    - 最后执行已批准的 query template 或受控访问方式
--
-- 3) 推荐的 DSL 字段使用方式
--    - gateway_data_policy.condition_dsl_json 推荐引用 logical_field_code
--    - 由 gateway_external_data_asset_field 负责把逻辑字段映射为物理字段
--
-- 4) 初期不建议做的事情
--    - 不建议把客户侧数据库账号权限作为唯一安全边界
--    - 不建议把外部 group 或 role 直接映射为原始 SQL 片段
--
