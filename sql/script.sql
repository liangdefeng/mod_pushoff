CREATE TABLE IF NOT EXISTS `pushoff_tbl`(
  `bare_jid`        VARCHAR(100) NOT NULL comment "user@server",
  `push_type`       INT(1) NOT NULL default 0 comment "0 for normal, 1 for voip.",
  `token`           VARCHAR(100) NOT NULL comment "device token",
  `backend_server`  VARCHAR(30) NOT NULL comment "backend server",
  `backend_id`      VARCHAR(30) NOT NULL comment "sample value: mod_pushoff_apns_h2",
  `backend_ref`     VARCHAR(20) NOT NULL comment "sample value: sandbox_voip",
  `apns_enviroment`     VARCHAR(20) default 'production' NOT NULL comment "sample value: sandbox / production",
  `timestamp`       BIGINT NOT NULL,
  PRIMARY KEY(`bare_jid`, `push_type`)
);

CREATE INDEX pushoff_tbl_index1 ON `pushoff_tbl`(`timestamp`);
CREATE INDEX pushoff_tbl_index2 ON `pushoff_tbl`(`bare_jid`);