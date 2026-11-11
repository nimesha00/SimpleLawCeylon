-- Law practice management system (Sri Lanka) - database schema
-- PostgreSQL 14+
-- Rule: every firm-owned table carries firm_id, and every query filters by it.

-- =========================================================
-- TIER 1 - FOUNDATION
-- =========================================================

CREATE TABLE plans (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            text NOT NULL,
    price_lkr       numeric(12,2) NOT NULL,
    billing_period  text NOT NULL CHECK (billing_period IN ('monthly','yearly')),
    max_users       int NOT NULL DEFAULT 1,
    is_active       boolean NOT NULL DEFAULT true
);

CREATE TABLE firms (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            text NOT NULL,
    address         text,
    phone           text,
    email           text,
    logo_url        text,
    tax_name        text,                   -- shown on invoices; NULL = no tax
    tax_rate_percent numeric(5,2) NOT NULL DEFAULT 0,
    status          text NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active','inactive','read_only')),
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- firm_id is NULL only for platform admins.
CREATE TABLE users (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    firm_id         bigint REFERENCES firms(id),
    role            text NOT NULL CHECK (role IN
                    ('platform_admin','firm_owner','partner','junior','clerk','accountant')),
    full_name       text NOT NULL,
    email           text NOT NULL UNIQUE,
    phone           text,
    password_hash   text NOT NULL,
    two_fa_enabled  boolean NOT NULL DEFAULT true,
    is_active       boolean NOT NULL DEFAULT true,
    failed_login_count int NOT NULL DEFAULT 0,
    locked_until    timestamptz,
    last_login_at   timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CHECK ((role = 'platform_admin') = (firm_id IS NULL))
);

-- Server-side sessions, so a login can be revoked at once.
CREATE TABLE sessions (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         bigint NOT NULL REFERENCES users(id),
    token_hash      text NOT NULL UNIQUE,
    ip_address      text,
    user_agent      text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    last_seen_at    timestamptz NOT NULL DEFAULT now(),
    expires_at      timestamptz NOT NULL,
    revoked_at      timestamptz
);

-- Single-use password reset links.
CREATE TABLE password_reset_tokens (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         bigint NOT NULL REFERENCES users(id),
    token_hash      text NOT NULL UNIQUE,
    expires_at      timestamptz NOT NULL,
    used_at         timestamptz
);

-- Each firm can adjust what its staff roles may do.
CREATE TABLE role_permissions (
    firm_id         bigint NOT NULL REFERENCES firms(id),
    role            text NOT NULL CHECK (role IN ('partner','junior','clerk','accountant')),
    permission      text NOT NULL,          -- e.g. 'cases.edit', 'invoices.view'
    PRIMARY KEY (firm_id, role, permission)
);

-- Email one-time codes for 2FA.
CREATE TABLE login_otps (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         bigint NOT NULL REFERENCES users(id),
    code_hash       text NOT NULL,
    expires_at      timestamptz NOT NULL,
    used_at         timestamptz
);

CREATE TABLE audit_logs (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    firm_id         bigint REFERENCES firms(id),
    user_id         bigint REFERENCES users(id),
    action          text NOT NULL,          -- 'create','update','delete','login','export','print'
    entity          text NOT NULL,          -- table name
    entity_id       bigint,
    changes         jsonb,                  -- old and new values
    ip_address      text,
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_logs_firm_idx ON audit_logs (firm_id, created_at DESC);

-- One Google Drive per firm. The refresh token must be encrypted by the application.
CREATE TABLE drive_connections (
    firm_id                 bigint PRIMARY KEY REFERENCES firms(id),
    google_email            text NOT NULL,
    refresh_token_encrypted text NOT NULL,
    root_folder_id          text NOT NULL,
    deeds_folder_id         text,
    status                  text NOT NULL DEFAULT 'connected'
                            CHECK (status IN ('connected','disconnected','error')),
    connected_by            bigint REFERENCES users(id),
    connected_at            timestamptz NOT NULL DEFAULT now()
);

-- Auto numbering for deeds, invoices and receipts, per firm and year.
CREATE TABLE firm_counters (
    firm_id         bigint NOT NULL REFERENCES firms(id),
    counter_key     text NOT NULL,          -- 'deed','invoice','receipt'
    year            int NOT NULL,
    last_value      int NOT NULL DEFAULT 0,
    PRIMARY KEY (firm_id, counter_key, year)
);

-- =========================================================
-- TIER 2 - ADMIN MASTER DATA
-- =========================================================

CREATE TABLE subscriptions (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    firm_id         bigint NOT NULL REFERENCES firms(id),
    plan_id         bigint NOT NULL REFERENCES plans(id),
    price_lkr       numeric(12,2),          -- per-firm override; NULL = plan price
    max_users       int,                    -- per-firm override; NULL = plan limit
    starts_on       date NOT NULL,
    ends_on         date NOT NULL,
    status          text NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active','expired','cancelled'))
);

CREATE TABLE subscription_payments (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    subscription_id bigint NOT NULL REFERENCES subscriptions(id),
    amount_lkr      numeric(12,2) NOT NULL,
    method          text,                   -- 'bank_transfer','card','cash'
    reference       text,
    paid_at         timestamptz NOT NULL DEFAULT now()
);

-- Law library, maintained by the platform admin.
CREATE TABLE laws (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title           text NOT NULL,          -- e.g. 'Civil Procedure Code'
    act_number      text,
    year            int,
    category        text,                   -- 'civil','criminal','land','labour','family'
    summary         text,
    source_url      text,
    is_active       boolean NOT NULL DEFAULT true
);

CREATE TABLE law_sections (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    law_id          bigint NOT NULL REFERENCES laws(id) ON DELETE CASCADE,
    section_number  text NOT NULL,
    heading         text,
    body            text
);
CREATE INDEX law_sections_law_idx ON law_sections (law_id);

-- firm_id NULL = default list supplied by the platform; a firm can add its own.
CREATE TABLE courts (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    firm_id         bigint REFERENCES firms(id),
    name            text NOT NULL,
    court_type      text,                   -- 'Supreme Court','District Court', ...
    city            text,
    address         text
);

CREATE TABLE case_types (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    firm_id         bigint REFERENCES firms(id),
    name            text NOT NULL
);

CREATE TABLE case_statuses (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    firm_id         bigint REFERENCES firms(id),
    name            text NOT NULL,
    is_closed       boolean NOT NULL DEFAULT false,
    sort_order      int NOT NULL DEFAULT 0
);

-- Template body holds placeholders such as {{client.name}} or {{case.number}}.
CREATE TABLE document_templates (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    firm_id         bigint REFERENCES firms(id),
    name            text NOT NULL,          -- 'Plaint','Power of attorney','Demand letter'
    language        text NOT NULL DEFAULT 'en' CHECK (language IN ('en','si','ta')),
    body            text NOT NULL
);

-- =========================================================
-- TIER 3 - CORE RECORDS
-- =========================================================

CREATE TABLE clients (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    firm_id         bigint NOT NULL REFERENCES firms(id),
    client_type     text NOT NULL DEFAULT 'individual'
                    CHECK (client_type IN ('individual','company')),
    full_name       text NOT NULL,
    nic_encrypted   text,                   -- NIC or company registration number
    nic_hash        text,                   -- for exact-match search and conflict check
    phone           text,
    email           text,
    address         text,
    notes           text,
    portal_enabled  boolean NOT NULL DEFAULT false,
    drive_folder_id text,
    created_by      bigint REFERENCES users(id),
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX clients_firm_name_idx ON clients (firm_id, full_name);
CREATE INDEX clients_firm_nic_idx  ON clients (firm_id, nic_hash);

CREATE TABLE cases (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    firm_id         bigint NOT NULL REFERENCES firms(id),
    client_id       bigint NOT NULL REFERENCES clients(id),
    case_number     text,                   -- court case number
    title           text NOT NULL,
    court_id        bigint REFERENCES courts(id),
    case_type_id    bigint REFERENCES case_types(id),
    status_id       bigint REFERENCES case_statuses(id),
    lead_lawyer_id  bigint REFERENCES users(id),
    filed_on        date,
    closed_on       date,
    description     text,
    drive_folder_id text,
    created_by      bigint REFERENCES users(id),
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX cases_firm_client_idx ON cases (firm_id, client_id);

-- Other people in a case. The conflict check searches this table and clients.
CREATE TABLE case_parties (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    firm_id         bigint NOT NULL REFERENCES firms(id),
    case_id         bigint NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    party_role      text NOT NULL,          -- 'plaintiff','defendant','witness','opposing_counsel'
    full_name       text NOT NULL,
    nic_hash        text,
    contact         text
);
CREATE INDEX case_parties_firm_name_idx ON case_parties (firm_id, full_name);

CREATE TABLE case_staff (
    case_id         bigint NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    user_id         bigint NOT NULL REFERENCES users(id),
    PRIMARY KEY (case_id, user_id)
);

-- Laws tagged to a case; drives "search law against the case".
CREATE TABLE case_laws (
    case_id         bigint NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    law_id          bigint NOT NULL REFERENCES laws(id),
    law_section_id  bigint REFERENCES law_sections(id),
    note            text
);
CREATE UNIQUE INDEX case_laws_uniq
    ON case_laws (case_id, law_id, COALESCE(law_section_id, 0));

-- Running history of the case: notes, status changes, hearing outcomes.
CREATE TABLE case_events (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    firm_id         bigint NOT NULL REFERENCES firms(id),
    case_id         bigint NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    event_type      text NOT NULL,          -- 'note','status_change','hearing','document','payment'
    description     text NOT NULL,
    created_by      bigint REFERENCES users(id),
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX case_events_case_idx ON case_events (case_id, created_at DESC);

-- =========================================================
-- TIER 4 - DAILY WORK
-- =========================================================

CREATE TABLE hearings (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    firm_id         bigint NOT NULL REFERENCES firms(id),
    case_id         bigint NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    court_id        bigint REFERENCES courts(id),
    starts_at       timestamptz NOT NULL,
    ends_at         timestamptz,
    location        text,                   -- court room or other place
    purpose         text,                   -- 'trial','calling','inquiry','order'
    assigned_to     bigint REFERENCES users(id),
    outcome         text,
    next_hearing_id bigint REFERENCES hearings(id),
    status          text NOT NULL DEFAULT 'scheduled'
                    CHECK (status IN ('scheduled','done','postponed','cancelled'))
);
CREATE INDEX hearings_firm_date_idx ON hearings (firm_id, starts_at);

-- Tasks, appointments and time-slot bookings; case and client are optional.
CREATE TABLE tasks (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    firm_id         bigint NOT NULL REFERENCES firms(id),
    case_id         bigint REFERENCES cases(id) ON DELETE CASCADE,
    client_id       bigint REFERENCES clients(id),
    title           text NOT NULL,
    details         text,
    task_type       text NOT NULL DEFAULT 'task'
                    CHECK (task_type IN ('task','appointment','deadline')),
    starts_at       timestamptz,
    due_at          timestamptz,
    location        text,
    assigned_to     bigint REFERENCES users(id),
    status          text NOT NULL DEFAULT 'open'
                    CHECK (status IN ('open','done','cancelled')),
    created_by      bigint REFERENCES users(id),
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX tasks_firm_due_idx ON tasks (firm_id, status, due_at);

CREATE TABLE deeds (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    firm_id         bigint NOT NULL REFERENCES firms(id),
    deed_number     text NOT NULL,          -- generated from firm_counters
    deed_type       text NOT NULL,          -- 'transfer','mortgage','gift','lease','last will'
    deed_date       date NOT NULL,
    client_id       bigint REFERENCES clients(id),
    property_description text,
    property_location    text,
    extent          text,
    consideration_lkr    numeric(14,2),
    land_registry   text,
    registry_reminder_at timestamptz,       -- date and time picked by the lawyer
    registry_status text NOT NULL DEFAULT 'pending'
                    CHECK (registry_status IN ('pending','submitted','registered')),
    notes           text,
    created_by      bigint REFERENCES users(id),
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (firm_id, deed_number)
);

CREATE TABLE deed_parties (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    deed_id         bigint NOT NULL REFERENCES deeds(id) ON DELETE CASCADE,
    party_role      text NOT NULL,          -- 'vendor','purchaser','donor','donee','witness'
    full_name       text NOT NULL,
    nic_hash        text,
    address         text
);

-- Files live in the firm's Google Drive; this table holds the link and details.
CREATE TABLE documents (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    firm_id         bigint NOT NULL REFERENCES firms(id),
    client_id       bigint REFERENCES clients(id),
    case_id         bigint REFERENCES cases(id),
    deed_id         bigint REFERENCES deeds(id),
    template_id     bigint REFERENCES document_templates(id),
    file_name       text NOT NULL,
    mime_type       text,
    drive_file_id   text NOT NULL,
    drive_status    text NOT NULL DEFAULT 'ok' CHECK (drive_status IN ('ok','missing')),
    uploaded_by     bigint REFERENCES users(id),
    uploaded_at     timestamptz NOT NULL DEFAULT now(),
    CHECK (client_id IS NOT NULL OR case_id IS NOT NULL OR deed_id IS NOT NULL)
);
CREATE INDEX documents_case_idx ON documents (firm_id, case_id);

-- Email or SMS reminders for a hearing, a task or a deed.
CREATE TABLE reminders (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    firm_id         bigint NOT NULL REFERENCES firms(id),
    user_id         bigint NOT NULL REFERENCES users(id),
    hearing_id      bigint REFERENCES hearings(id) ON DELETE CASCADE,
    task_id         bigint REFERENCES tasks(id) ON DELETE CASCADE,
    deed_id         bigint REFERENCES deeds(id) ON DELETE CASCADE,
    remind_at       timestamptz NOT NULL,
    channel         text NOT NULL DEFAULT 'email' CHECK (channel IN ('email','sms')),
    message         text,
    sent_at         timestamptz
);
CREATE INDEX reminders_due_idx ON reminders (remind_at) WHERE sent_at IS NULL;

CREATE TABLE time_entries (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    firm_id         bigint NOT NULL REFERENCES firms(id),
    case_id         bigint NOT NULL REFERENCES cases(id),
    user_id         bigint NOT NULL REFERENCES users(id),
    work_date       date NOT NULL,
    minutes         int NOT NULL CHECK (minutes > 0),
    rate_lkr        numeric(12,2) NOT NULL DEFAULT 0,   -- per hour
    description     text,
    invoice_item_id bigint                  -- set once billed
);

CREATE TABLE expenses (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    firm_id         bigint NOT NULL REFERENCES firms(id),
    case_id         bigint REFERENCES cases(id),
    expense_date    date NOT NULL,
    category        text,                   -- 'stamp fees','court fees','travel','copies'
    amount_lkr      numeric(12,2) NOT NULL,
    description     text,
    billable        boolean NOT NULL DEFAULT true,
    invoice_item_id bigint,                 -- set once billed
    created_by      bigint REFERENCES users(id)
);

-- =========================================================
-- TIER 5 - MONEY
-- =========================================================

CREATE TABLE invoices (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    firm_id         bigint NOT NULL REFERENCES firms(id),
    client_id       bigint NOT NULL REFERENCES clients(id),
    case_id         bigint REFERENCES cases(id),
    invoice_number  text NOT NULL,          -- generated from firm_counters
    issue_date      date NOT NULL,
    due_date        date NOT NULL,
    subtotal_lkr    numeric(14,2) NOT NULL DEFAULT 0,
    tax_lkr         numeric(14,2) NOT NULL DEFAULT 0,
    total_lkr       numeric(14,2) NOT NULL DEFAULT 0,
    paid_lkr        numeric(14,2) NOT NULL DEFAULT 0,
    status          text NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft','sent','part_paid','paid','cancelled')),
    notes           text,
    created_by      bigint REFERENCES users(id),
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (firm_id, invoice_number)
);
CREATE INDEX invoices_firm_status_idx ON invoices (firm_id, status, due_date);

CREATE TABLE invoice_items (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_id      bigint NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    description     text NOT NULL,
    quantity        numeric(10,2) NOT NULL DEFAULT 1,
    unit_price_lkr  numeric(12,2) NOT NULL,
    amount_lkr      numeric(14,2) NOT NULL
);

ALTER TABLE time_entries ADD FOREIGN KEY (invoice_item_id) REFERENCES invoice_items(id);
ALTER TABLE expenses     ADD FOREIGN KEY (invoice_item_id) REFERENCES invoice_items(id);

CREATE TABLE payments (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    firm_id         bigint NOT NULL REFERENCES firms(id),
    invoice_id      bigint NOT NULL REFERENCES invoices(id),
    amount_lkr      numeric(14,2) NOT NULL CHECK (amount_lkr > 0),
    receipt_number  text NOT NULL,          -- generated from firm_counters
    method          text NOT NULL,          -- 'cash','cheque','bank_transfer','from_trust'
    reference       text,
    paid_on         date NOT NULL,
    recorded_by     bigint REFERENCES users(id),
    UNIQUE (firm_id, receipt_number)
);

-- Simple record of client money held: received, used, refunded.
-- Balance per client = sum of amount_lkr (deposits positive, the rest negative).
CREATE TABLE trust_transactions (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    firm_id         bigint NOT NULL REFERENCES firms(id),
    client_id       bigint NOT NULL REFERENCES clients(id),
    case_id         bigint REFERENCES cases(id),
    txn_type        text NOT NULL CHECK (txn_type IN ('deposit','used','refund')),
    amount_lkr      numeric(14,2) NOT NULL,
    payment_id      bigint REFERENCES payments(id),
    description     text,
    txn_date        date NOT NULL,
    recorded_by     bigint REFERENCES users(id)
);
CREATE INDEX trust_client_idx ON trust_transactions (firm_id, client_id, txn_date);

-- =========================================================
-- PUBLIC HOME PAGE (platform admin)
-- =========================================================

CREATE TABLE site_slides (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    image_url       text NOT NULL,
    caption         text,
    sort_order      int NOT NULL DEFAULT 0,
    is_active       boolean NOT NULL DEFAULT true
);

CREATE TABLE site_news (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title           text NOT NULL,
    body            text NOT NULL,
    published_at    timestamptz
);

CREATE TABLE contact_messages (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            text NOT NULL,
    email           text NOT NULL,
    message         text NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now()
);
