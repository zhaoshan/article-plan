-- --------------------------------------------
-- Gateway 租户 / 纯 RBAC / SSO 接入能力 - MySQL DDL 初稿
-- 日期：2026-08-25
-- 数据库：MySQL 8.x
--
-- 说明：
-- 1) 本稿以现有 gateway_user / gateway_refresh_token / gateway_password_reset_token 为基础扩展。
-- 2) 新增表均可直接落库；现有 gateway_user 的兼容升级建议放在脚本最前，需结合现网表结构择机执行。
-- 3) 本稿为纯 RBAC 版本：内部仅保留 role / permission，不引入内部 group 模型。
-- 4) 延续当前项目风格：不强依赖物理外键，主要依靠业务唯一键、索引和应用层校验。
-- --------------------------------------------

SET NAMES utf8mb4;

USE `ai_chat_insight`;

-- ============================================================
-- A. gateway_user 兼容升级建议（按现网 schema 状态择机执行）
-- ============================================================
--
-- 设计意图：
-- - tenant_id：保留为兼容字段，迁移期可镜像默认进入的 tenant。
-- - default_tenant_id：新增，表示用户默认进入的 tenant。
-- - user_status：统一账号状态。
-- - last_login_provider：记录最近一次登录来源。
--
-- 示例：
-- ALTER TABLE `gateway_user`
--   ADD COLUMN `default_tenant_id` CHAR(32) DEFAULT NULL COMMENT '默认进入的 tenant_id；迁移期可替代历史 tenant_id 入口语义' AFTER `tenant_id`,
--   ADD COLUMN `user_status` VARCHAR(16) NOT NULL DEFAULT 'ACTIVE' COMMENT '账号状态：PENDING/ACTIVE/SUSPENDED/DELETED' AFTER `auth_provider`,
--   ADD COLUMN `display_name` VARCHAR(128) DEFAULT NULL COMMENT '展示名；可与 full_name 并存' AFTER `full_name`,
--   ADD COLUMN `last_login_provider` VARCHAR(64) DEFAULT NULL COMMENT '最近一次登录提供方：password/google/microsoft/okta/keycloak 等' AFTER `last_login_time`;
--
-- ALTER TABLE `gateway_user`
--   MODIFY COLUMN `tenant_id` CHAR(32) DEFAULT NULL COMMENT '兼容字段：历史 workspaceId；迁移期可镜像 default_tenant_id';
--
-- CREATE INDEX `idx_default_tenant_id` ON `gateway_user` (`default_tenant_id`);
-- CREATE INDEX `idx_user_status` ON `gateway_user` (`user_status`);

-- ============================================================
-- B. 租户主表
-- ============================================================

CREATE TABLE IF NOT EXISTS `gateway_tenant` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `tenant_id` CHAR(32) NOT NULL COMMENT '租户业务唯一标识（UUID，无横线 32 位）',
  `tenant_code` VARCHAR(64) NOT NULL COMMENT '租户编码/slug；用于 URL、外部展示或后台检索',
  `tenant_name` VARCHAR(128) NOT NULL COMMENT '租户名称；个人租户可默认取用户昵称，企业租户取公司名',
  `tenant_type` VARCHAR(16) NOT NULL COMMENT '租户类型：PERSONAL/ORGANIZATION',
  `tenant_status` VARCHAR(16) NOT NULL DEFAULT 'ACTIVE' COMMENT '租户状态：PENDING/ACTIVE/SUSPENDED/DELETED',
  `registration_source` VARCHAR(16) NOT NULL DEFAULT 'SELF_SERVICE' COMMENT '注册来源：SELF_SERVICE/ADMIN/IMPORT/SALES',
  `owner_user_id` CHAR(32) DEFAULT NULL COMMENT '首个拥有者用户ID；逻辑关联 gateway_user.user_id',
  `primary_domain` VARCHAR(255) DEFAULT NULL COMMENT '主域名；企业租户可为空，待验证后回填',
  `join_policy` VARCHAR(16) NOT NULL DEFAULT 'INVITE_ONLY' COMMENT '加入策略：INVITE_ONLY/DOMAIN_REQUEST/DOMAIN_AUTO_JOIN/SSO_ONLY',
  `sso_required` TINYINT NOT NULL DEFAULT 0 COMMENT '是否强制走企业 SSO：0否 1是',
  `billing_plan_code` VARCHAR(64) DEFAULT NULL COMMENT '计费套餐编码；可为空，供后续商业化使用',
  `settings_json` JSON DEFAULT NULL COMMENT '租户级配置 JSON；如品牌、默认语言、功能开关等',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_tenant_id` (`tenant_id`),
  UNIQUE KEY `uk_gateway_tenant_code` (`tenant_code`),
  KEY `idx_tenant_type_status` (`tenant_type`, `tenant_status`),
  KEY `idx_owner_user_id` (`owner_user_id`),
  KEY `idx_primary_domain` (`primary_domain`),
  KEY `idx_create_time` (`create_time`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='租户主表（个人空间 / 企业空间统一抽象）';

-- ============================================================
-- C. 租户域名与域名验证
-- ============================================================

CREATE TABLE IF NOT EXISTS `gateway_tenant_domain` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `tenant_domain_id` CHAR(32) NOT NULL COMMENT '租户域名业务唯一标识',
  `tenant_id` CHAR(32) NOT NULL COMMENT '所属租户ID；逻辑关联 gateway_tenant.tenant_id',
  `domain` VARCHAR(255) NOT NULL COMMENT '域名，如 example.com',
  `domain_type` VARCHAR(16) NOT NULL DEFAULT 'COMPANY' COMMENT '域名类型：COMPANY/PUBLIC/ALIAS',
  `verification_status` VARCHAR(16) NOT NULL DEFAULT 'PENDING' COMMENT '验证状态：PENDING/VERIFIED/FAILED/EXPIRED/REVOKED',
  `join_policy` VARCHAR(16) NOT NULL DEFAULT 'REQUEST' COMMENT '域名加入策略：DISABLED/REQUEST/AUTO_JOIN/SSO_ONLY',
  `is_primary` TINYINT NOT NULL DEFAULT 0 COMMENT '是否主域名：0否 1是',
  `is_public_email_domain` TINYINT NOT NULL DEFAULT 0 COMMENT '是否公共邮箱域名：0否 1是',
  `verified_at` DATETIME DEFAULT NULL COMMENT '验证通过时间',
  `last_checked_at` DATETIME DEFAULT NULL COMMENT '最近一次校验时间',
  `remarks` VARCHAR(512) DEFAULT NULL COMMENT '备注；用于说明此域名用途或例外情况',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_tenant_domain_id` (`tenant_domain_id`),
  UNIQUE KEY `uk_gateway_domain` (`domain`),
  KEY `idx_tenant_id` (`tenant_id`),
  KEY `idx_verification_status` (`verification_status`),
  KEY `idx_join_policy` (`join_policy`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='租户可识别域名表；用于公司邮箱识别、加入策略和域名验证';

CREATE TABLE IF NOT EXISTS `gateway_tenant_domain_challenge` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `tenant_domain_challenge_id` CHAR(32) NOT NULL COMMENT '域名验证挑战业务唯一标识',
  `tenant_domain_id` CHAR(32) NOT NULL COMMENT '所属租户域名ID；逻辑关联 gateway_tenant_domain.tenant_domain_id',
  `challenge_type` VARCHAR(16) NOT NULL COMMENT '挑战方式：DNS_TXT/HTTP_FILE/EMAIL',
  `challenge_status` VARCHAR(16) NOT NULL DEFAULT 'PENDING' COMMENT '挑战状态：PENDING/VERIFIED/FAILED/EXPIRED/CANCELLED',
  `challenge_token` VARCHAR(255) NOT NULL COMMENT '挑战令牌；如 DNS TXT token 或文件 token',
  `challenge_payload` VARCHAR(1024) DEFAULT NULL COMMENT '挑战附加内容；如完整 TXT 值或 HTTP 文件内容',
  `expires_at` DATETIME NOT NULL COMMENT '挑战过期时间',
  `verified_at` DATETIME DEFAULT NULL COMMENT '挑战通过时间',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_tenant_domain_challenge_id` (`tenant_domain_challenge_id`),
  UNIQUE KEY `uk_gateway_domain_challenge_token` (`challenge_token`),
  KEY `idx_tenant_domain_id` (`tenant_domain_id`),
  KEY `idx_challenge_status` (`challenge_status`),
  KEY `idx_expires_at` (`expires_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='租户域名验证挑战表';

-- ============================================================
-- D. 用户与租户成员关系
-- ============================================================

CREATE TABLE IF NOT EXISTS `gateway_membership` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `membership_id` CHAR(32) NOT NULL COMMENT '成员关系业务唯一标识',
  `tenant_id` CHAR(32) NOT NULL COMMENT '所属租户ID；逻辑关联 gateway_tenant.tenant_id',
  `user_id` CHAR(32) NOT NULL COMMENT '所属用户ID；逻辑关联 gateway_user.user_id',
  `membership_status` VARCHAR(16) NOT NULL DEFAULT 'ACTIVE' COMMENT '成员状态：PENDING/ACTIVE/SUSPENDED/REMOVED',
  `join_source` VARCHAR(16) NOT NULL DEFAULT 'SELF_REGISTER' COMMENT '加入来源：SELF_REGISTER/INVITE/SSO/JIT/ADMIN/IMPORT',
  `is_default` TINYINT NOT NULL DEFAULT 0 COMMENT '是否默认进入该租户：0否 1是',
  `invited_by_user_id` CHAR(32) DEFAULT NULL COMMENT '邀请人用户ID',
  `approved_by_user_id` CHAR(32) DEFAULT NULL COMMENT '审批人用户ID',
  `joined_at` DATETIME DEFAULT NULL COMMENT '正式加入时间',
  `suspended_at` DATETIME DEFAULT NULL COMMENT '暂停时间',
  `left_at` DATETIME DEFAULT NULL COMMENT '离开/移除时间',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_membership_id` (`membership_id`),
  UNIQUE KEY `uk_gateway_membership_tenant_user` (`tenant_id`, `user_id`),
  KEY `idx_user_id` (`user_id`),
  KEY `idx_membership_status` (`membership_status`),
  KEY `idx_tenant_default` (`tenant_id`, `is_default`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='用户与租户的成员关系表；支持一个用户加入多个租户';

-- ============================================================
-- E. 外部身份 / 本地身份绑定
-- ============================================================

CREATE TABLE IF NOT EXISTS `gateway_user_identity` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `user_identity_id` CHAR(32) NOT NULL COMMENT '用户身份绑定业务唯一标识',
  `user_id` CHAR(32) NOT NULL COMMENT '所属用户ID；逻辑关联 gateway_user.user_id',
  `provider_type` VARCHAR(16) NOT NULL COMMENT '身份协议类型：LOCAL/OIDC/SAML',
  `provider_key` VARCHAR(64) NOT NULL COMMENT '身份提供方标识：password/google/microsoft/okta/keycloak/auth0/custom',
  `issuer` VARCHAR(255) DEFAULT NULL COMMENT 'OIDC/SAML issuer / entityId；本地密码登录可为空',
  `subject` VARCHAR(255) DEFAULT NULL COMMENT '外部身份主键；推荐存 OIDC sub 或 SAML NameID',
  `external_tenant_key` VARCHAR(128) DEFAULT NULL COMMENT '外部 IdP 的组织/租户标识；如 Azure tid',
  `login_name` VARCHAR(255) DEFAULT NULL COMMENT '外部登录名；如 email / upn / preferred_username',
  `email_at_idp` VARCHAR(255) DEFAULT NULL COMMENT '身份提供方返回的邮箱',
  `email_verified` TINYINT NOT NULL DEFAULT 0 COMMENT '邮箱是否在 IdP 侧已验证：0否 1是',
  `full_name_at_idp` VARCHAR(255) DEFAULT NULL COMMENT 'IdP 侧展示名',
  `phone_at_idp` VARCHAR(64) DEFAULT NULL COMMENT 'IdP 侧手机号',
  `identity_status` VARCHAR(16) NOT NULL DEFAULT 'ACTIVE' COMMENT '身份绑定状态：ACTIVE/DISABLED/REVOKED',
  `claims_json` JSON DEFAULT NULL COMMENT '原始或裁剪后的 claims 快照；用于审计与排障',
  `last_login_at` DATETIME DEFAULT NULL COMMENT '最近一次使用该身份登录时间',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_user_identity_id` (`user_identity_id`),
  UNIQUE KEY `uk_gateway_identity_provider_subject` (`provider_type`, `provider_key`, `issuer`, `subject`),
  KEY `idx_user_id` (`user_id`),
  KEY `idx_email_at_idp` (`email_at_idp`),
  KEY `idx_identity_status` (`identity_status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='用户外部身份 / 本地身份绑定表；支持 password、OIDC、SAML 并存';

-- ============================================================
-- F. 租户级 IdP / SSO 配置
-- ============================================================

CREATE TABLE IF NOT EXISTS `gateway_tenant_idp_config` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `tenant_idp_config_id` CHAR(32) NOT NULL COMMENT '租户 IdP 配置业务唯一标识',
  `tenant_id` CHAR(32) NOT NULL COMMENT '所属租户ID；逻辑关联 gateway_tenant.tenant_id',
  `protocol` VARCHAR(16) NOT NULL COMMENT '协议：OIDC/SAML',
  `provider_key` VARCHAR(64) NOT NULL COMMENT '提供方标识：google/microsoft/okta/keycloak/auth0/custom',
  `display_name` VARCHAR(128) NOT NULL COMMENT '前端展示名称，如 Company SSO',
  `config_status` VARCHAR(16) NOT NULL DEFAULT 'DRAFT' COMMENT '配置状态：DRAFT/ACTIVE/DISABLED',
  `issuer` VARCHAR(255) DEFAULT NULL COMMENT 'OIDC issuer 或 SAML entityId',
  `discovery_uri` VARCHAR(512) DEFAULT NULL COMMENT 'OIDC discovery 地址',
  `jwk_set_uri` VARCHAR(512) DEFAULT NULL COMMENT 'OIDC JWKS 地址',
  `authorization_endpoint` VARCHAR(512) DEFAULT NULL COMMENT '授权地址；支持 Auth Code + PKCE',
  `token_endpoint` VARCHAR(512) DEFAULT NULL COMMENT '换 token 地址',
  `userinfo_endpoint` VARCHAR(512) DEFAULT NULL COMMENT 'userinfo 地址；可选',
  `client_id` VARCHAR(255) DEFAULT NULL COMMENT '客户端 ID',
  `client_secret_cipher` TEXT DEFAULT NULL COMMENT '加密后的客户端密钥或 SAML 私钥材料',
  `scopes_json` JSON DEFAULT NULL COMMENT 'OIDC scopes 数组 JSON；如 [\"openid\",\"profile\",\"email\"]',
  `claim_mapping_json` JSON DEFAULT NULL COMMENT 'claim 映射配置 JSON；定义 email/name/sub/groups 如何映射到内部字段',
  `allowed_domains_json` JSON DEFAULT NULL COMMENT '允许使用该 IdP 的邮箱域名 JSON 数组',
  `pkce_required` TINYINT NOT NULL DEFAULT 1 COMMENT '是否要求 PKCE：0否 1是',
  `email_verified_required` TINYINT NOT NULL DEFAULT 0 COMMENT '是否要求 claim.email_verified=true：0否 1是',
  `jit_provisioning_enabled` TINYINT NOT NULL DEFAULT 1 COMMENT '是否启用首次登录自动建号/建成员关系：0否 1是',
  `default_join_policy` VARCHAR(16) NOT NULL DEFAULT 'REQUEST' COMMENT '首次登录时的默认加入策略：REQUEST/AUTO_JOIN/INVITE_ONLY',
  `metadata_xml` LONGTEXT DEFAULT NULL COMMENT 'SAML 元数据 XML；仅 protocol=SAML 时使用',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_tenant_idp_config_id` (`tenant_idp_config_id`),
  UNIQUE KEY `uk_gateway_tenant_protocol_provider_issuer` (`tenant_id`, `protocol`, `provider_key`, `issuer`),
  KEY `idx_config_status` (`config_status`),
  KEY `idx_tenant_protocol` (`tenant_id`, `protocol`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='租户级身份提供方配置表；支持 OIDC / SAML';

-- ============================================================
-- G. RBAC：角色与权限
-- ============================================================

CREATE TABLE IF NOT EXISTS `gateway_role` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `role_id` CHAR(32) NOT NULL COMMENT '角色业务唯一标识',
  `scope_type` VARCHAR(16) NOT NULL COMMENT '作用域类型：PLATFORM/TENANT',
  `scope_id` CHAR(32) NOT NULL COMMENT '作用域标识；scope_type=TENANT 时取 tenant_id，PLATFORM 时可固定为 PLATFORM',
  `role_code` VARCHAR(64) NOT NULL COMMENT '角色编码；如 TENANT_ADMIN/BUILDER/VIEWER',
  `role_name` VARCHAR(128) NOT NULL COMMENT '角色名称',
  `role_description` VARCHAR(512) DEFAULT NULL COMMENT '角色描述',
  `is_builtin` TINYINT NOT NULL DEFAULT 0 COMMENT '是否内置角色：0否 1是',
  `role_status` VARCHAR(16) NOT NULL DEFAULT 'ACTIVE' COMMENT '角色状态：ACTIVE/DISABLED',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_role_id` (`role_id`),
  UNIQUE KEY `uk_gateway_role_scope_code` (`scope_type`, `scope_id`, `role_code`),
  KEY `idx_scope_type_scope_id` (`scope_type`, `scope_id`),
  KEY `idx_role_status` (`role_status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='角色表；既可承载平台级角色，也可承载租户级角色';

CREATE TABLE IF NOT EXISTS `gateway_permission` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `permission_id` CHAR(32) NOT NULL COMMENT '权限业务唯一标识',
  `permission_code` VARCHAR(128) NOT NULL COMMENT '权限编码；如 agent.build.edit / tenant.member.invite',
  `resource_type` VARCHAR(64) NOT NULL COMMENT '资源类型；如 TENANT/USER/AGENT/KNOWLEDGE/OPENAPI',
  `action` VARCHAR(64) NOT NULL COMMENT '动作；如 VIEW/EDIT/DELETE/INVITE/DEPLOY',
  `permission_name` VARCHAR(128) NOT NULL COMMENT '权限名称',
  `permission_description` VARCHAR(512) DEFAULT NULL COMMENT '权限描述',
  `is_builtin` TINYINT NOT NULL DEFAULT 1 COMMENT '是否内置权限：0否 1是',
  `permission_status` VARCHAR(16) NOT NULL DEFAULT 'ACTIVE' COMMENT '权限状态：ACTIVE/DISABLED',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_permission_id` (`permission_id`),
  UNIQUE KEY `uk_gateway_permission_code` (`permission_code`),
  KEY `idx_resource_type_action` (`resource_type`, `action`),
  KEY `idx_permission_status` (`permission_status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='权限字典表';

CREATE TABLE IF NOT EXISTS `gateway_role_permission` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `role_permission_id` CHAR(32) NOT NULL COMMENT '角色权限关系业务唯一标识',
  `role_id` CHAR(32) NOT NULL COMMENT '角色ID；逻辑关联 gateway_role.role_id',
  `permission_id` CHAR(32) NOT NULL COMMENT '权限ID；逻辑关联 gateway_permission.permission_id',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_role_permission_id` (`role_permission_id`),
  UNIQUE KEY `uk_gateway_role_permission_pair` (`role_id`, `permission_id`),
  KEY `idx_permission_id` (`permission_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='角色与权限关联表';

CREATE TABLE IF NOT EXISTS `gateway_membership_role` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `membership_role_id` CHAR(32) NOT NULL COMMENT '成员角色关系业务唯一标识',
  `membership_id` CHAR(32) NOT NULL COMMENT '成员关系ID；逻辑关联 gateway_membership.membership_id',
  `role_id` CHAR(32) NOT NULL COMMENT '角色ID；逻辑关联 gateway_role.role_id',
  `grant_source` VARCHAR(16) NOT NULL DEFAULT 'DIRECT' COMMENT '授予来源：DIRECT/GROUP/IDP_SYNC',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_membership_role_id` (`membership_role_id`),
  UNIQUE KEY `uk_gateway_membership_role_pair` (`membership_id`, `role_id`),
  KEY `idx_role_id` (`role_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='成员与角色关联表';

-- ============================================================
-- H. IdP Group 到内部角色映射
-- ============================================================

CREATE TABLE IF NOT EXISTS `gateway_idp_group_mapping` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `idp_group_mapping_id` CHAR(32) NOT NULL COMMENT 'IdP 组映射业务唯一标识',
  `tenant_idp_config_id` CHAR(32) NOT NULL COMMENT '租户 IdP 配置ID；逻辑关联 gateway_tenant_idp_config.tenant_idp_config_id',
  `match_mode` VARCHAR(16) NOT NULL DEFAULT 'EXACT' COMMENT '匹配模式：EXACT/REGEX',
  `match_value` VARCHAR(255) NOT NULL COMMENT '外部 group 值或正则表达式',
  `target_role_id` CHAR(32) NOT NULL COMMENT '目标角色ID；逻辑关联 gateway_role.role_id',
  `priority` INT NOT NULL DEFAULT 100 COMMENT '匹配优先级；数值越小优先级越高',
  `mapping_status` VARCHAR(16) NOT NULL DEFAULT 'ACTIVE' COMMENT '映射状态：ACTIVE/DISABLED',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_idp_group_mapping_id` (`idp_group_mapping_id`),
  UNIQUE KEY `uk_gateway_idp_group_mapping_rule` (`tenant_idp_config_id`, `match_mode`, `match_value`, `target_role_id`),
  KEY `idx_target_role_id` (`target_role_id`),
  KEY `idx_mapping_status_priority` (`mapping_status`, `priority`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='IdP group/role 到内部角色的映射规则表（纯 RBAC 版本）';

-- ============================================================
-- I. 邀请与加入申请
-- ============================================================

CREATE TABLE IF NOT EXISTS `gateway_invitation` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `invitation_id` CHAR(32) NOT NULL COMMENT '邀请业务唯一标识',
  `tenant_id` CHAR(32) NOT NULL COMMENT '目标租户ID',
  `email` VARCHAR(255) NOT NULL COMMENT '被邀请邮箱',
  `invite_type` VARCHAR(16) NOT NULL DEFAULT 'EMAIL' COMMENT '邀请类型：EMAIL/LINK/BULK_IMPORT',
  `invitation_status` VARCHAR(16) NOT NULL DEFAULT 'PENDING' COMMENT '邀请状态：PENDING/ACCEPTED/EXPIRED/REVOKED',
  `invite_token_hash` VARCHAR(128) NOT NULL COMMENT '邀请 token 的 hash 值；避免明文落库',
  `default_role_id` CHAR(32) DEFAULT NULL COMMENT '默认授予角色ID',
  `invited_by_user_id` CHAR(32) DEFAULT NULL COMMENT '发起邀请的用户ID',
  `accepted_by_user_id` CHAR(32) DEFAULT NULL COMMENT '接受邀请的用户ID',
  `message` VARCHAR(512) DEFAULT NULL COMMENT '邀请备注或附言',
  `expires_at` DATETIME NOT NULL COMMENT '邀请过期时间',
  `accepted_at` DATETIME DEFAULT NULL COMMENT '接受时间',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_invitation_id` (`invitation_id`),
  UNIQUE KEY `uk_gateway_invite_token_hash` (`invite_token_hash`),
  KEY `idx_tenant_email_status` (`tenant_id`, `email`, `invitation_status`),
  KEY `idx_expires_at` (`expires_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='租户邀请表';

CREATE TABLE IF NOT EXISTS `gateway_join_request` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `join_request_id` CHAR(32) NOT NULL COMMENT '加入申请业务唯一标识',
  `tenant_id` CHAR(32) NOT NULL COMMENT '目标租户ID',
  `user_id` CHAR(32) DEFAULT NULL COMMENT '申请用户ID；申请发起时可能已登录，也可能仅凭邮箱',
  `email` VARCHAR(255) NOT NULL COMMENT '申请邮箱',
  `request_source` VARCHAR(16) NOT NULL DEFAULT 'DOMAIN_DISCOVERY' COMMENT '申请来源：DOMAIN_DISCOVERY/SSO/JOIN_PAGE/ADMIN',
  `request_status` VARCHAR(16) NOT NULL DEFAULT 'PENDING' COMMENT '申请状态：PENDING/APPROVED/REJECTED/CANCELLED',
  `request_reason` VARCHAR(512) DEFAULT NULL COMMENT '申请原因/补充说明',
  `reviewed_by_user_id` CHAR(32) DEFAULT NULL COMMENT '审批人用户ID',
  `review_note` VARCHAR(512) DEFAULT NULL COMMENT '审批备注',
  `reviewed_at` DATETIME DEFAULT NULL COMMENT '审批时间',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_join_request_id` (`join_request_id`),
  KEY `idx_tenant_email_status` (`tenant_id`, `email`, `request_status`),
  KEY `idx_user_id` (`user_id`),
  KEY `idx_reviewed_at` (`reviewed_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='加入租户申请表';

-- ============================================================
-- J. 审计日志
-- ============================================================

CREATE TABLE IF NOT EXISTS `gateway_audit_log` (
  `id` BIGINT NOT NULL AUTO_INCREMENT COMMENT '自增主键',
  `audit_log_id` CHAR(32) NOT NULL COMMENT '审计日志业务唯一标识',
  `tenant_id` CHAR(32) DEFAULT NULL COMMENT '租户ID；平台级操作可为空',
  `actor_user_id` CHAR(32) DEFAULT NULL COMMENT '操作者用户ID',
  `actor_membership_id` CHAR(32) DEFAULT NULL COMMENT '操作者成员关系ID',
  `event_type` VARCHAR(64) NOT NULL COMMENT '事件类型；如 TENANT_CREATED/INVITE_SENT/ROLE_GRANTED/SSO_LOGIN',
  `target_type` VARCHAR(64) NOT NULL COMMENT '目标类型；如 TENANT/USER/MEMBERSHIP/IDP_CONFIG/ROLE',
  `target_id` VARCHAR(128) DEFAULT NULL COMMENT '目标业务ID',
  `result_status` VARCHAR(16) NOT NULL DEFAULT 'SUCCESS' COMMENT '结果状态：SUCCESS/FAILED/DENIED',
  `trace_id` VARCHAR(64) DEFAULT NULL COMMENT '链路追踪ID；用于串联跨系统请求',
  `request_id` VARCHAR(64) DEFAULT NULL COMMENT '请求ID；用于应用层排障',
  `ip_address` VARCHAR(64) DEFAULT NULL COMMENT '来源 IP 地址',
  `user_agent` VARCHAR(512) DEFAULT NULL COMMENT '来源 User-Agent',
  `before_json` JSON DEFAULT NULL COMMENT '变更前快照 JSON',
  `after_json` JSON DEFAULT NULL COMMENT '变更后快照 JSON',
  `metadata_json` JSON DEFAULT NULL COMMENT '扩展元数据 JSON；如 email/domain/issuer 等',
  `delete_flag` TINYINT NOT NULL DEFAULT 0 COMMENT '0正常 1删除；审计表通常不建议物理删除',
  `create_by` VARCHAR(64) DEFAULT NULL COMMENT '创建人',
  `update_by` VARCHAR(64) DEFAULT NULL COMMENT '最后修改人',
  `create_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_gateway_audit_log_id` (`audit_log_id`),
  KEY `idx_tenant_event_time` (`tenant_id`, `event_type`, `create_time`),
  KEY `idx_actor_user_id` (`actor_user_id`),
  KEY `idx_target_type_id` (`target_type`, `target_id`),
  KEY `idx_trace_id` (`trace_id`),
  KEY `idx_request_id` (`request_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='租户 / 权限 / SSO 相关审计日志表';

-- ============================================================
-- K. 设计补充说明
-- ============================================================
--
-- 1) 推荐的个人 / 企业注册语义
--    - PERSONAL：注册即创建个人 tenant，并自动生成一条 ACTIVE membership。
--    - ORGANIZATION：创建企业 tenant 后，由首个管理员持有 ACTIVE membership。
--
-- 2) 推荐的 Claim 映射落点
--    - OIDC/SAML 原始 claims 存 gateway_user_identity.claims_json。
--    - IdP 级 claim 映射规则存 gateway_tenant_idp_config.claim_mapping_json。
--    - 外部组映射到内部角色的规则存 gateway_idp_group_mapping。
--
-- 3) 推荐的迁移路径
--    - 第一步：新增本脚本中的新表。
--    - 第二步：为现有 gateway_user 补 default_tenant_id / user_status 等兼容字段。
--    - 第三步：逐步把业务读写从 gateway_user.tenant_id 迁移到 gateway_membership / gateway_tenant。
--
-- 4) 数据权限说明
--    - 本稿仅覆盖功能权限（RBAC）。
--    - 若后续需要外部数据权限映射，建议在 RBAC 之外补一层 ABAC / Data Policy，不与 role_permission 混在一起。
--
