-- db/schema/01_structure.sql
-- Физическая модель FoodExpress (FOOD-101)
-- Схема: leshchenko_food

CREATE SCHEMA IF NOT EXISTS leshchenko_food;

-- 1. Пользовательские перечислимые типы (8 enum-типов по BR)

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE t.typname = 'restaurant_status' AND n.nspname = 'leshchenko_food') THEN
        CREATE TYPE leshchenko_food.restaurant_status AS ENUM ('активен', 'неактивен');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE t.typname = 'product_status' AND n.nspname = 'leshchenko_food') THEN
        CREATE TYPE leshchenko_food.product_status AS ENUM ('доступно', 'нет_в_наличии', 'архив');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE t.typname = 'courier_status' AND n.nspname = 'leshchenko_food') THEN
        CREATE TYPE leshchenko_food.courier_status AS ENUM ('свободен', 'занят', 'на_доставке', 'уволен');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE t.typname = 'order_status' AND n.nspname = 'leshchenko_food') THEN
        CREATE TYPE leshchenko_food.order_status AS ENUM ('создан', 'готовится', 'в_доставке', 'доставлен', 'отменён');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE t.typname = 'order_pay_status' AND n.nspname = 'leshchenko_food') THEN
        CREATE TYPE leshchenko_food.order_pay_status AS ENUM ('ожидает', 'оплачен', 'ошибка');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE t.typname = 'payment_status' AND n.nspname = 'leshchenko_food') THEN
        CREATE TYPE leshchenko_food.payment_status AS ENUM ('успех', 'ошибка', 'в_обработке');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE t.typname = 'payment_type' AND n.nspname = 'leshchenko_food') THEN
        CREATE TYPE leshchenko_food.payment_type AS ENUM ('карта', 'наличные', 'безнал');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE t.typname = 'review_entity_type' AND n.nspname = 'leshchenko_food') THEN
        CREATE TYPE leshchenko_food.review_entity_type AS ENUM ('блюдо', 'ресторан', 'заказ');
    END IF;
END $$;

-- 2. Таблицы модели (12 таблиц концептуальной ERD)

-- 2.1. client (BR-2)
CREATE TABLE IF NOT EXISTS leshchenko_food.client (
    client_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    login varchar(100) NOT NULL UNIQUE,
    password varchar(32) NOT NULL,
    phone_number varchar(12) NOT NULL UNIQUE,
    CONSTRAINT chk_client_login_nonempty CHECK (length(btrim(login)) > 0),
    CONSTRAINT chk_client_password_md5 CHECK (password ~ '^[0-9a-f]{32}$'),
    CONSTRAINT chk_client_phone_nonempty CHECK (length(btrim(phone_number)) > 0)
);

-- 2.2. address (BR-3)
CREATE TABLE IF NOT EXISTS leshchenko_food.address (
    address_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    street varchar(200) NOT NULL,
    house_number varchar(30) NOT NULL,
    apartment_office varchar(30),
    CONSTRAINT chk_address_street_nonempty CHECK (length(btrim(street)) > 0),
    CONSTRAINT chk_address_house_nonempty CHECK (length(btrim(house_number)) > 0),
    CONSTRAINT chk_address_apt_nonempty CHECK (apartment_office IS NULL OR length(btrim(apartment_office)) > 0),
    CONSTRAINT uq_address_physical UNIQUE NULLS NOT DISTINCT (street, house_number, apartment_office)
);

-- 2.3. client_address (BR-2.4, BR-2.5)
CREATE TABLE IF NOT EXISTS leshchenko_food.client_address (
    client_id uuid NOT NULL REFERENCES leshchenko_food.client(client_id) ON DELETE NO ACTION,
    address_id uuid NOT NULL REFERENCES leshchenko_food.address(address_id) ON DELETE NO ACTION,
    PRIMARY KEY (client_id, address_id)
);

-- 2.4. restaurant (BR-3.3, BR-4)
CREATE TABLE IF NOT EXISTS leshchenko_food.restaurant (
    restaurant_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    restaurant_name varchar(200) NOT NULL,
    address_id uuid NOT NULL UNIQUE REFERENCES leshchenko_food.address(address_id) ON DELETE NO ACTION,
    description text NOT NULL,
    work_start time NOT NULL,
    work_end time NOT NULL,
    company_details text NOT NULL,
    rating numeric(3,2),
    status leshchenko_food.restaurant_status NOT NULL,
    CONSTRAINT chk_restaurant_name_nonempty CHECK (length(btrim(restaurant_name)) > 0),
    CONSTRAINT chk_restaurant_desc_nonempty CHECK (length(btrim(description)) > 0),
    CONSTRAINT chk_restaurant_details_nonempty CHECK (length(btrim(company_details)) > 0),
    CONSTRAINT chk_restaurant_work_hours CHECK (work_end > work_start),
    CONSTRAINT chk_restaurant_rating_range CHECK (rating IS NULL OR (rating >= 0.00 AND rating <= 5.00))
);

-- 2.5. courier (BR-6)
CREATE TABLE IF NOT EXISTS leshchenko_food.courier (
    courier_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    FIO varchar(200) NOT NULL,
    phone_number varchar(12) NOT NULL,
    status leshchenko_food.courier_status NOT NULL,
    hire_date date NOT NULL,
    dismissal_date date,
    coefficient numeric(2,1) NOT NULL DEFAULT 0.1,
    CONSTRAINT chk_courier_fio_nonempty CHECK (length(btrim(FIO)) > 0),
    CONSTRAINT chk_courier_phone_nonempty CHECK (length(btrim(phone_number)) > 0),
    CONSTRAINT chk_courier_coefficient_range CHECK (coefficient >= 0.1 AND coefficient <= 0.5),
    CONSTRAINT chk_courier_dates CHECK (dismissal_date IS NULL OR dismissal_date >= hire_date),
    CONSTRAINT chk_courier_status_dismissal CHECK (
        (status = 'уволен' AND dismissal_date IS NOT NULL) OR
        (status != 'уволен' AND dismissal_date IS NULL)
    )
);

-- 2.6. courier_pay (BR-10)
CREATE TABLE IF NOT EXISTS leshchenko_food.courier_pay (
    year integer NOT NULL,
    month integer NOT NULL,
    courier_id uuid NOT NULL REFERENCES leshchenko_food.courier(courier_id) ON DELETE NO ACTION,
    amount numeric(14,2) NOT NULL,
    coefficient_used numeric(2,1) NOT NULL,
    PRIMARY KEY (year, month, courier_id),
    CONSTRAINT chk_courier_pay_year CHECK (year >= 1),
    CONSTRAINT chk_courier_pay_month CHECK (month >= 1 AND month <= 12),
    CONSTRAINT chk_courier_pay_amount_positive CHECK (amount >= 0.00),
    CONSTRAINT chk_courier_pay_coeff_range CHECK (coefficient_used >= 0.1 AND coefficient_used <= 0.5)
);

-- 2.7. product_category (BR-5.7)
CREATE TABLE IF NOT EXISTS leshchenko_food.product_category (
    product_category_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    product_category_name varchar(200) NOT NULL,
    CONSTRAINT chk_product_category_name_nonempty CHECK (length(btrim(product_category_name)) > 0)
);

-- 2.8. product (BR-5)
CREATE TABLE IF NOT EXISTS leshchenko_food.product (
    product_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    product_name varchar(200) NOT NULL,
    product_category_id uuid NOT NULL REFERENCES leshchenko_food.product_category(product_category_id) ON DELETE NO ACTION,
    price numeric(14,2) NOT NULL,
    restaurant_id uuid NOT NULL REFERENCES leshchenko_food.restaurant(restaurant_id) ON DELETE NO ACTION,
    photo_url text,
    rating numeric(3,2),
    status leshchenko_food.product_status NOT NULL,
    description text NOT NULL,
    CONSTRAINT chk_product_name_nonempty CHECK (length(btrim(product_name)) > 0),
    CONSTRAINT chk_product_price_nonnegative CHECK (price >= 0.00),
    CONSTRAINT chk_product_rating_range CHECK (rating IS NULL OR (rating >= 0.00 AND rating <= 5.00)),
    CONSTRAINT chk_product_desc_nonempty CHECK (length(btrim(description)) > 0),
    CONSTRAINT chk_product_photo_nonempty CHECK (photo_url IS NULL OR length(btrim(photo_url)) > 0)
);

-- 2.9. "order" (BR-7)
CREATE TABLE IF NOT EXISTS leshchenko_food."order" (
    order_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    courier_id uuid NOT NULL REFERENCES leshchenko_food.courier(courier_id) ON DELETE NO ACTION,
    client_id uuid NOT NULL REFERENCES leshchenko_food.client(client_id) ON DELETE NO ACTION,
    address_id uuid NOT NULL REFERENCES leshchenko_food.address(address_id) ON DELETE NO ACTION,
    restaurant_id uuid NOT NULL REFERENCES leshchenko_food.restaurant(restaurant_id) ON DELETE NO ACTION,
    order_timestamp timestamp NOT NULL,
    delivery_timestamp timestamp,
    order_amount numeric(14,2) NOT NULL,
    commission numeric(14,2) NOT NULL,
    total_amount numeric(14,2) NOT NULL,
    status leshchenko_food.order_status NOT NULL,
    pay_status leshchenko_food.order_pay_status NOT NULL,
    description text NOT NULL,
    CONSTRAINT fk_order_client_address FOREIGN KEY (client_id, address_id)
        REFERENCES leshchenko_food.client_address(client_id, address_id) ON DELETE NO ACTION,
    CONSTRAINT uq_order_id_client_id UNIQUE (order_id, client_id),
    CONSTRAINT chk_order_amount_nonnegative CHECK (order_amount >= 0.00),
    CONSTRAINT chk_order_commission_calc CHECK (commission = round(order_amount * 0.10, 2)),
    CONSTRAINT chk_order_total_calc CHECK (total_amount = order_amount + commission),
    CONSTRAINT chk_order_min_total CHECK (total_amount >= 1000.00),
    CONSTRAINT chk_order_delivery_time CHECK (delivery_timestamp IS NULL OR delivery_timestamp >= order_timestamp),
    CONSTRAINT chk_order_delivery_status CHECK (
        (status = 'доставлен' AND delivery_timestamp IS NOT NULL) OR
        (status != 'доставлен' AND delivery_timestamp IS NULL)
    ),
    CONSTRAINT chk_order_desc_nonempty CHECK (length(btrim(description)) > 0)
);

-- 2.10. order_structure (BR-7.14, BR-7.15, BR-7.16)
CREATE TABLE IF NOT EXISTS leshchenko_food.order_structure (
    order_id uuid NOT NULL REFERENCES leshchenko_food."order"(order_id) ON DELETE NO ACTION,
    product_id uuid NOT NULL REFERENCES leshchenko_food.product(product_id) ON DELETE NO ACTION,
    quantity numeric(12,3) NOT NULL,
    unit_price numeric(14,2) NOT NULL,
    PRIMARY KEY (order_id, product_id),
    CONSTRAINT chk_order_structure_quantity_positive CHECK (quantity > 0),
    CONSTRAINT chk_order_structure_unit_price_nonnegative CHECK (unit_price >= 0.00)
);

-- 2.11. payment (BR-8)
CREATE TABLE IF NOT EXISTS leshchenko_food.payment (
    payment_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    order_id uuid NOT NULL REFERENCES leshchenko_food."order"(order_id) ON DELETE NO ACTION,
    payment_type leshchenko_food.payment_type NOT NULL,
    amount numeric(14,2) NOT NULL,
    transaction_id uuid NOT NULL UNIQUE DEFAULT exts.uuid_generate_v4(),
    transaction_timestamp timestamp NOT NULL,
    status leshchenko_food.payment_status NOT NULL,
    CONSTRAINT chk_payment_amount_nonnegative CHECK (amount >= 0.00)
);

-- 2.12. review (BR-9)
CREATE TABLE IF NOT EXISTS leshchenko_food.review (
    review_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    client_id uuid NOT NULL,
    order_id uuid NOT NULL,
    review_timestamp timestamp NOT NULL,
    entity_id uuid NOT NULL,
    entity_type leshchenko_food.review_entity_type NOT NULL,
    description text NOT NULL,
    photo_url text,
    rating numeric(2,1) NOT NULL,
    CONSTRAINT fk_review_order_client FOREIGN KEY (order_id, client_id)
        REFERENCES leshchenko_food."order"(order_id, client_id) ON DELETE NO ACTION,
    CONSTRAINT uq_review_order_entity UNIQUE (order_id, entity_type, entity_id),
    CONSTRAINT chk_review_rating_range CHECK (rating >= 1.0 AND rating <= 5.0),
    CONSTRAINT chk_review_desc_nonempty CHECK (length(btrim(description)) > 0),
    CONSTRAINT chk_review_photo_nonempty CHECK (photo_url IS NULL OR length(btrim(photo_url)) > 0)
);

-- 3. Вспомогательный триггер для снимка цены позиции (order_structure.unit_price)

CREATE OR REPLACE FUNCTION leshchenko_food.set_order_line_price()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.unit_price IS NULL THEN
        SELECT price INTO NEW.unit_price
        FROM leshchenko_food.product
        WHERE product_id = NEW.product_id;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_order_structure_set_price ON leshchenko_food.order_structure;
CREATE TRIGGER trg_order_structure_set_price
BEFORE INSERT ON leshchenko_food.order_structure
FOR EACH ROW
EXECUTE FUNCTION leshchenko_food.set_order_line_price();

-- 4. Индексы

CREATE UNIQUE INDEX IF NOT EXISTS uq_payment_order_success
    ON leshchenko_food.payment (order_id)
    WHERE status = 'успех';

CREATE INDEX IF NOT EXISTS idx_review_entity
    ON leshchenko_food.review (entity_type, entity_id);

CREATE INDEX IF NOT EXISTS idx_order_structure_product
    ON leshchenko_food.order_structure (product_id);

CREATE INDEX IF NOT EXISTS idx_order_restaurant
    ON leshchenko_food."order" (restaurant_id);

CREATE INDEX IF NOT EXISTS idx_order_courier_delivered
    ON leshchenko_food."order" (courier_id, order_timestamp)
    WHERE status = 'доставлен';

CREATE INDEX IF NOT EXISTS idx_payment_order
    ON leshchenko_food.payment (order_id);
