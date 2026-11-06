-- db/schema/grants.sql
-- Создание роли-аудитора inspector и назначение прав (FOOD-109)

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'inspector') THEN
        CREATE ROLE inspector WITH LOGIN PASSWORD 'NetoSQL2025';
    ELSE
        ALTER ROLE inspector WITH LOGIN PASSWORD 'NetoSQL2025';
    END IF;
END $$;

-- Права на схему решения leshchenko_food
GRANT USAGE, CREATE ON SCHEMA leshchenko_food TO inspector;
GRANT ALL PRIVILEGES ON SCHEMA leshchenko_food TO inspector;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA leshchenko_food TO inspector;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA leshchenko_food TO inspector;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA leshchenko_food TO inspector;
GRANT ALL PRIVILEGES ON ALL PROCEDURES IN SCHEMA leshchenko_food TO inspector;

ALTER DEFAULT PRIVILEGES IN SCHEMA leshchenko_food GRANT ALL ON TABLES TO inspector;
ALTER DEFAULT PRIVILEGES IN SCHEMA leshchenko_food GRANT ALL ON SEQUENCES TO inspector;
ALTER DEFAULT PRIVILEGES IN SCHEMA leshchenko_food GRANT ALL ON FUNCTIONS TO inspector;

-- Права на пользовательские enum-типы
GRANT USAGE ON TYPE leshchenko_food.restaurant_status TO inspector;
GRANT USAGE ON TYPE leshchenko_food.product_status TO inspector;
GRANT USAGE ON TYPE leshchenko_food.courier_status TO inspector;
GRANT USAGE ON TYPE leshchenko_food.order_status TO inspector;
GRANT USAGE ON TYPE leshchenko_food.order_pay_status TO inspector;
GRANT USAGE ON TYPE leshchenko_food.payment_status TO inspector;
GRANT USAGE ON TYPE leshchenko_food.payment_type TO inspector;
GRANT USAGE ON TYPE leshchenko_food.review_entity_type TO inspector;

-- Права на внешнюю схему exts и системные каталоги
GRANT USAGE ON SCHEMA exts TO inspector;
GRANT USAGE ON SCHEMA information_schema TO inspector;
GRANT USAGE ON SCHEMA pg_catalog TO inspector;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA exts TO inspector;

-- Настройка search_path для роли inspector в текущей базе данных
DO $$
BEGIN
    EXECUTE format('ALTER ROLE inspector IN DATABASE %I SET search_path = leshchenko_food, exts, pg_catalog', current_database());
END $$;
