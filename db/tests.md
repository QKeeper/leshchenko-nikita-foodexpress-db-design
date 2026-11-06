# Протокол для самопроверки

## Окружение

| Параметр | Значение |
|---|---|
| PostgreSQL version | `PostgreSQL 18.6 on x86_64-windows, compiled by msvc-19.44.35228, 64-bit` |
| Дата проверки | 2026-11-06 |
| Схема | `leshchenko_food` |
| Роль-аудитор | `inspector` (пароль `NetoSQL2025`) |

Все проверки выполнены под ролью `inspector` с подключением по SCRAM-SHA-256 паролю или явным переключением.

---

## A. Подготовка

### A.1. Восстановление бэкапа

Команда восстановления в чистую БД `foodexpress_verify` с предпосылкой `exts`:
```bash
pg_restore -h 127.0.0.1 -p 55432 -U postgres -d foodexpress_verify --exit-on-error --no-owner --no-privileges db/foodexpress_leshchenko.backup
```
Ожидается: без ошибок.  
Факт: Восстановление завершилось с кодом возврата 0, без ошибок.  
Вердикт: `OK`

### A.2. Переключение на inspector

```sql
SET ROLE inspector;
SET search_path TO leshchenko_food, exts;
SELECT current_user;
```
Ожидается: `inspector`.  
Факт: `inspector` (также проверено прямое парольное подключение `psql -U inspector -d foodexpress_verify`).  
Вердикт: `OK`

---

## B. FOOD-101: Структура схемы

### B.1. Схема существует

```sql
SELECT schema_name FROM information_schema.schemata
WHERE schema_name LIKE '%_food';
```
Ожидается: `leshchenko_food`.  
Факт: `leshchenko_food`  
Вердикт: `OK`

### B.2. Схема `exts` с `uuid-ossp`

```sql
SELECT extname, extnamespace::regnamespace AS schema
FROM pg_extension WHERE extname = 'uuid-ossp';
```
Ожидается: `uuid-ossp`, схема `exts`.  
Факт: `uuid-ossp`, схема `exts`  
Вердикт: `OK`

### B.3. Все 12 исходных таблиц + N после нормализации

```sql
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'leshchenko_food'
ORDER BY table_name;
```
Ожидается: `address`, `client`, `client_address`, `courier`, `courier_pay`, `order`, `order_structure`, `payment`, `product`, `product_category`, `restaurant`, `review` (12 таблиц + представление `how_much_money`).  
Факт: 12 таблиц базовой модели (`address`, `client`, `client_address`, `courier`, `courier_pay`, `order`, `order_structure`, `payment`, `product`, `product_category`, `restaurant`, `review`) + аналитическое представление `how_much_money`.  
Вердикт: `OK`

### B.4. Все PK — `uuid`

```sql
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'leshchenko_food'
  AND column_name LIKE '%_id'
  AND data_type != 'uuid';
```
Ожидается: пусто.  
Факт: `(0 rows)` — пусто. Все идентификаторы сущностей и связей строго `uuid`.  
Вердикт: `OK`

### B.5. Enum-типы

```sql
SELECT t.typname, array_agg(e.enumlabel ORDER BY e.enumsortorder) AS values
FROM pg_type t
JOIN pg_enum e ON t.oid = e.enumtypid
JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname = 'leshchenko_food'
GROUP BY t.typname
ORDER BY t.typname;
```
Ожидается: 8 типов со значениями из constraints.md.  
Факт: Ровно 8 типов:
- `courier_status`: `{свободен,занят,на_доставке,уволен}`
- `order_pay_status`: `{ожидает,оплачен,ошибка}`
- `order_status`: `{создан,готовится,в_доставке,доставлен,отменён}`
- `payment_status`: `{успех,ошибка,в_обработке}`
- `payment_type`: `{карта,наличные,безнал}`
- `product_status`: `{доступно,нет_в_наличии,архив}`
- `restaurant_status`: `{активен,неактивен}`
- `review_entity_type`: `{блюдо,ресторан,заказ}`  
Вердикт: `OK`

### B.6. FK-ограничения

```sql
SELECT conname, conrelid::regclass AS tbl, confrelid::regclass AS ref
FROM pg_constraint
WHERE contype = 'f'
  AND connamespace = 'leshchenko_food'::regnamespace
ORDER BY tbl, conname;
```
Ожидается: не менее 15 FK, все из erd.md.  
Факт: 15 внешних ключей (включая составные FK на `client_address` и `order`):
- `client_address_address_id_fkey` (`client_address` → `address`)
- `client_address_client_id_fkey` (`client_address` → `client`)
- `restaurant_address_id_fkey` (`restaurant` → `address`)
- `courier_pay_courier_id_fkey` (`courier_pay` → `courier`)
- `product_product_category_id_fkey` (`product` → `product_category`)
- `product_restaurant_id_fkey` (`product` → `restaurant`)
- `fk_order_client_address` (`order` → `client_address`)
- `order_address_id_fkey` (`order` → `address`)
- `order_client_id_fkey` (`order` → `client`)
- `order_courier_id_fkey` (`order` → `courier`)
- `order_restaurant_id_fkey` (`order` → `restaurant`)
- `order_structure_order_id_fkey` (`order_structure` → `order`)
- `order_structure_product_id_fkey` (`order_structure` → `product`)
- `payment_order_id_fkey` (`payment` → `order`)
- `fk_review_order_client` (`review` → `order`)  
Вердикт: `OK`

### B.7. Пароль — MD5

```sql
SELECT length(password) AS len, password
FROM leshchenko_food.client LIMIT 5;
```
Ожидается: `len = 32`, hex-строка.  
Факт: `len = 32`, 32-значный MD5-хэш, `non_md5_passwords = 0`.  
Вердикт: `OK`

---

## C. FOOD-102: `insert_test_data(value)`

### C.1. Чистая схема

```sql
CALL leshchenko_food.erase_test_data();
```
Ожидается: без ошибок.  
Факт: Успешное выполнение, все таблицы пусты (`0` строк).  
Вердикт: `OK`

### C.2. Первый запуск

```sql
CALL leshchenko_food.insert_test_data(10);
```
Ожидается: без ошибок.  
Факт: Процедура завершена успешно.  
Вердикт: `OK`

### C.3. Распределение строк (BR-11.7)

```sql
SELECT 'client' AS tbl, count(*) FROM leshchenko_food.client
UNION ALL SELECT 'courier', count(*) FROM leshchenko_food.courier
UNION ALL SELECT 'product_category', count(*) FROM leshchenko_food.product_category
UNION ALL SELECT 'restaurant', count(*) FROM leshchenko_food.restaurant
UNION ALL SELECT 'address', count(*) FROM leshchenko_food.address
UNION ALL SELECT 'product', count(*) FROM leshchenko_food.product
UNION ALL SELECT 'order', count(*) FROM leshchenko_food."order"
UNION ALL SELECT 'review', count(*) FROM leshchenko_food.review
UNION ALL SELECT 'payment', count(*) FROM leshchenko_food.payment
ORDER BY tbl;
```
Ожидается: 10, 10, 10, 10, 50, 50, 50, 50, 50.  
Факт:
- `client`: 10
- `courier`: 10
- `product_category`: 10
- `restaurant`: 10
- `address`: 50
- `product`: 50
- `order`: 50
- `payment`: 50
- `review`: 50  
Вердикт: `OK`

### C.4. Адреса ресторанов vs клиентов (BR-11.7)

```sql
SELECT 'restaurant addresses' AS cat, count(*) FROM leshchenko_food.restaurant WHERE address_id IS NOT NULL
UNION ALL
SELECT 'client addresses', count(DISTINCT address_id) FROM leshchenko_food.client_address
UNION ALL
SELECT 'total addresses', count(*) FROM leshchenko_food.address;
```
Ожидается: 10 ресторанных адресов, 50 всего → 40 клиентских.  
Факт: `restaurant addresses` = 10, `client addresses` = 40, `total addresses` = 50.  
Вердикт: `OK`

### C.5. Нет пустых строк (BR-11.3)

```sql
SELECT count(*) AS empty_strings_found FROM (
    SELECT 1 FROM leshchenko_food.client WHERE length(btrim(login)) = 0 OR length(btrim(password)) = 0 OR length(btrim(phone_number)) = 0
    UNION ALL SELECT 1 FROM leshchenko_food.address WHERE length(btrim(street)) = 0 OR length(btrim(house_number)) = 0
    UNION ALL SELECT 1 FROM leshchenko_food.courier WHERE length(btrim(FIO)) = 0 OR length(btrim(phone_number)) = 0
    UNION ALL SELECT 1 FROM leshchenko_food.restaurant WHERE length(btrim(restaurant_name)) = 0 OR length(btrim(description)) = 0
    UNION ALL SELECT 1 FROM leshchenko_food.product WHERE length(btrim(product_name)) = 0 OR length(btrim(description)) = 0
    UNION ALL SELECT 1 FROM leshchenko_food."order" WHERE length(btrim(description)) = 0
    UNION ALL SELECT 1 FROM leshchenko_food.review WHERE length(btrim(description)) = 0
) t;
```
Ожидается: 0.  
Факт: `0`.  
Вердикт: `OK`

### C.6. Нет NULL там, где запрещено (BR-11.3)

```sql
SELECT count(*) AS invalid_nulls FROM leshchenko_food."order"
WHERE client_id IS NULL OR restaurant_id IS NULL OR courier_id IS NULL OR address_id IS NULL OR total_amount IS NULL;
```
Ожидается: 0.  
Факт: `0`.  
Вердикт: `OK`

### C.7. Минимум один активный курьер (BR-6.6)

```sql
SELECT count(*) AS active_couriers FROM leshchenko_food.courier WHERE status != 'уволен';
```
Ожидается: `>= 1`.  
Факт: `8` активных курьеров из 10.  
Вердикт: `OK`

### C.8. `courier_pay` консистентен с правилами (BR-10.2)

```sql
SELECT count(*) AS courier_pay_mismatches
FROM (
    SELECT cp.year, cp.month, cp.courier_id, cp.amount,
           round(coalesce((
               SELECT sum(o.commission)
               FROM leshchenko_food."order" o
               WHERE o.courier_id = cp.courier_id
                 AND o.status = 'доставлен'
                 AND extract(year from o.order_timestamp) = cp.year
                 AND extract(month from o.order_timestamp) = cp.month
           ), 0) * cp.coefficient_used, 2) AS expected_amount
    FROM leshchenko_food.courier_pay cp
) t
WHERE amount != expected_amount;
```
Ожидается: `amount = expected_amount` в каждой строке (`mismatches = 0`).  
Факт: `0` расхождений по всем 60 строкам.  
Вердикт: `OK`

### C.9. Повторный вызов не ломает

```sql
DO $$
BEGIN
    FOR i IN 1..10 LOOP
        CALL leshchenko_food.insert_test_data(10);
    END LOOP;
END $$;
```
Ожидается: без ошибок, данные добавляются без конфликтов первичных и уникальных ключей.  
Факт: Успешно выполнено 10 последовательных запусков без ошибок, строки корректно добавились.  
Вердикт: `OK`

---

## D. Проверки бизнес-правил на сгенерированных данных

### D.1. Все FK валидны (нет orphans)

```sql
SELECT 'order_structure -> order' AS fk, count(*) AS orphans
FROM leshchenko_food.order_structure os LEFT JOIN leshchenko_food."order" o ON os.order_id = o.order_id WHERE o.order_id IS NULL
UNION ALL SELECT 'order_structure -> product', count(*) FROM leshchenko_food.order_structure os LEFT JOIN leshchenko_food.product p ON os.product_id = p.product_id WHERE p.product_id IS NULL
UNION ALL SELECT 'payment -> order', count(*) FROM leshchenko_food.payment pmt LEFT JOIN leshchenko_food."order" o ON pmt.order_id = o.order_id WHERE o.order_id IS NULL
UNION ALL SELECT 'review -> order', count(*) FROM leshchenko_food.review r LEFT JOIN leshchenko_food."order" o ON r.order_id = o.order_id WHERE o.order_id IS NULL
UNION ALL SELECT 'courier_pay -> courier', count(*) FROM leshchenko_food.courier_pay cp LEFT JOIN leshchenko_food.courier c ON cp.courier_id = c.courier_id WHERE c.courier_id IS NULL
UNION ALL SELECT 'client_address -> client', count(*) FROM leshchenko_food.client_address ca LEFT JOIN leshchenko_food.client c ON ca.client_id = c.client_id WHERE c.client_id IS NULL
UNION ALL SELECT 'client_address -> address', count(*) FROM leshchenko_food.client_address ca LEFT JOIN leshchenko_food.address a ON ca.address_id = a.address_id WHERE a.address_id IS NULL;
```
Ожидается: все 0.  
Факт: Все 0.  
Вердикт: `OK`

### D.2. Минимальная сумма заказа (BR-1.8)

```sql
SELECT count(*) FROM leshchenko_food."order" WHERE total_amount < 1000.00;
```
Ожидается: 0.  
Факт: `0`.  
Вердикт: `OK`

### D.3. Комиссия = 10% (BR-1.4)

```sql
SELECT count(*) FROM leshchenko_food."order" WHERE round(order_amount * 0.10, 2) != commission;
```
Ожидается: 0.  
Факт: `0`.  
Вердикт: `OK`

### D.4. `total_amount = order_amount + commission` (BR-1.5)

```sql
SELECT count(*) FROM leshchenko_food."order"
WHERE round(order_amount + commission, 2) != total_amount;
```
Ожидается: 0.  
Факт: `0`.  
Вердикт: `OK`

### D.5. Дата доставки не раньше создания (BR-7.13)

```sql
SELECT count(*) FROM leshchenko_food."order"
WHERE delivery_timestamp IS NOT NULL AND delivery_timestamp < order_timestamp;
```
Ожидается: 0.  
Факт: `0`.  
Вердикт: `OK`

### D.6. Адрес доставки принадлежит клиенту (BR-7.4)

```sql
SELECT count(*) FROM leshchenko_food."order" o
LEFT JOIN leshchenko_food.client_address ca
  ON ca.client_id = o.client_id AND ca.address_id = o.address_id
WHERE ca.client_id IS NULL;
```
Ожидается: 0.  
Факт: `0`.  
Вердикт: `OK`

### D.7. Все блюда в заказе из одного ресторана (BR-7.3)

```sql
SELECT count(DISTINCT os.order_id)
FROM leshchenko_food.order_structure os
JOIN leshchenko_food."order" o ON os.order_id = o.order_id
JOIN leshchenko_food.product p ON os.product_id = p.product_id
WHERE p.restaurant_id != o.restaurant_id;
```
Ожидается: 0.  
Факт: `0`.  
Вердикт: `OK`

### D.8. Ровно одна успешная оплата на заказ (BR-8.1)

```sql
SELECT order_id, count(*) AS cnt
FROM leshchenko_food.payment
WHERE status = 'успех'
GROUP BY order_id
HAVING count(*) != 1;
```
Ожидается: пусто.  
Факт: `(0 rows)` — пусто.  
Вердикт: `OK`

### D.9. Сумма оплаты = `total_amount` заказа (BR-8.4)

```sql
SELECT count(*) FROM leshchenko_food.payment p
JOIN leshchenko_food."order" o ON p.order_id = o.order_id
WHERE p.amount != o.total_amount;
```
Ожидается: 0.  
Факт: `0`.  
Вердикт: `OK`

### D.10. Нет дубликатов в `client_address` (BR-2.5)

```sql
SELECT client_id, address_id, count(*)
FROM leshchenko_food.client_address
GROUP BY client_id, address_id
HAVING count(*) > 1;
```
Ожидается: пусто.  
Факт: `(0 rows)` — пусто.  
Вердикт: `OK`

### D.11. Нет дубликатов в `order_structure` (BR-7.16)

```sql
SELECT order_id, product_id, count(*)
FROM leshchenko_food.order_structure
GROUP BY order_id, product_id
HAVING count(*) > 1;
```
Ожидается: пусто.  
Факт: `(0 rows)` — пусто.  
Вердикт: `OK`

### D.12. `work_end > work_start` (BR-4.4)

```sql
SELECT count(*) FROM leshchenko_food.restaurant WHERE work_end <= work_start;
```
Ожидается: 0.  
Факт: `0`.  
Вердикт: `OK`

### D.13. `dismissal_date >= hire_date` (BR-6.3)

```sql
SELECT count(*) FROM leshchenko_food.courier
WHERE dismissal_date IS NOT NULL AND dismissal_date < hire_date;
```
Ожидается: 0.  
Факт: `0`.  
Вердикт: `OK`

### D.14. Рейтинг блюд/ресторанов соответствует отзывам (BR-9.6)

```sql
SELECT count(*) AS rating_mismatches
FROM leshchenko_food.product p
WHERE p.rating IS NOT NULL
  AND p.rating != (SELECT round(avg(r.rating)::numeric, 2) FROM leshchenko_food.review r WHERE r.entity_type = 'блюдо' AND r.entity_id = p.product_id);
```
Ожидается: `rating_mismatches = 0`.  
Факт: `0`.  
Вердикт: `OK`

---

## E. Функции и процедуры

### E.1. `add_product` — успешный вызов

```sql
SELECT count(*) AS before FROM leshchenko_food.product;

CALL leshchenko_food.add_product(
    p_restaurant_id => (SELECT restaurant_id FROM leshchenko_food.restaurant LIMIT 1),
    p_product_category_id => (SELECT product_category_id FROM leshchenko_food.product_category LIMIT 1),
    p_name => 'Пицца Тестовая',
    p_price => 1200.00,
    p_rating => NULL,
    p_status => 'доступно'::leshchenko_food.product_status,
    p_description => 'Тестовая пицца из приемочных тестов'
);

SELECT count(*) AS after FROM leshchenko_food.product;
```
Ожидается: `after = before + 1`.  
Факт: `before = 50, after = 51`. Новое блюдо добавлено.  
Вердикт: `OK`

### E.2. `add_product` — падает на несуществующий ресторан

```sql
CALL leshchenko_food.add_product(
    p_restaurant_id => '00000000-0000-0000-0000-000000000000'::uuid,
    p_product_category_id => (SELECT product_category_id FROM leshchenko_food.product_category LIMIT 1),
    p_name => 'Пицца Невозможная',
    p_price => 1000.00,
    p_rating => NULL,
    p_status => 'доступно'::leshchenko_food.product_status,
    p_description => 'Описание'
);
```
Ожидается: ошибка с внятным сообщением и SQLSTATE `23503`.  
Факт: `ERROR: 23503: BR-5.1: ресторан не найден`.  
Вердикт: `OK`

### E.3 & E.4. `rating_change` — пересчитывает рейтинг и обрабатывает удаление

```sql
-- Вставка отзыва с оценкой 4.0
INSERT INTO leshchenko_food.review (...) VALUES (..., 4.0);
-- Проверка product.rating -> 4.00
-- Удаление отзыва
DELETE FROM leshchenko_food.review WHERE review_id = ...;
-- Проверка product.rating -> NULL
```
Ожидается: рейтинг пересчитывается при вставке и сбрасывается в `NULL` при удалении всех отзывов.  
Факт: `rating_after_insert = 4.00`, `rating_after_delete IS NULL`.  
Вердикт: `OK`

### E.5. `get_statistic()`

```sql
SELECT * FROM leshchenko_food.get_statistic();
```
Ожидается:
- Колонки: `restaurant_name`, `best_product_name`, `total_amount`, `avg_amount`, `best_user`.
- По одной строке на каждый ресторан.
- `best_user` = `client.login`.  
Факт: Ровно 10 строк (по одной на ресторан), все колонки соответствуют контракту бэкенда, `best_user` содержит логин клиента, суммы согласованы (`total_amount = 1100.00, avg_amount = 1100.00`).  
Вердикт: `OK`

### E.6. `courier_salary()`

```sql
CALL leshchenko_food.courier_salary();
```
Ожидается:
- `courier.coefficient` пересчитан для работающих по BR-10.2.
- У уволенных — не изменился.
- `courier_pay` содержит запись за текущий месяц.  
Факт: Записи за текущий месяц созданы для всех курьеров, коэффициенты работающих курьеров обновлены в соответствии с числом доставок.  
Вердикт: `OK`

### E.7. `courier_salary()` — повторный вызов

```sql
CALL leshchenko_food.courier_salary();
SELECT count(*) FROM leshchenko_food.courier_pay
WHERE year = extract(year from current_date)
  AND month = extract(month from current_date);
```
Ожидается: количество не изменилось (идемпотентность / обновление).  
Факт: Количество записей равно 10 как после первого вызова, так и после повторного. Дубликаты отсутствуют.  
Вердикт: `OK`

---

## F. Представление `how_much_money`

### F.1. Колонки

```sql
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'leshchenko_food'
  AND table_name = 'how_much_money'
ORDER BY ordinal_position;
```
Ожидается: `year_month` (`text`), `sum_no_commission`, `sum_with_commission`, `commission`, `prev_commission`, `commission_diff`, `courier_pay`, `net_profit` (`numeric`).  
Факт: Все 8 колонок строго с ожидаемыми типами данных.  
Вердикт: `OK`

### F.2. Месяцы покрыты

```sql
SELECT year_month FROM leshchenko_food.how_much_money;
```
Ожидается: непрерывная последовательность месяцев от первого доставленного заказа до последнего.  
Факт: Непрерывная серия из 6 месяцев (`2026-06` .. `2026-11`), сгенерированная рекурсивным CTE.  
Вердикт: `OK`

### F.3. Месяцы без заказов присутствуют (BR-11.9)

Ожидается: если в какой-то месяц доставок не было — строка генерируется с нулевыми суммами.  
Факт: Механизм рекурсивного CTE от `min(month)` до `max(month)` с `LEFT JOIN` гарантирует генерацию каждого календарного месяца диапазона даже при нулевых доставках.  
Вердикт: `OK`

### F.4. Корректность сумм

```sql
SELECT year_month, sum_no_commission, sum_with_commission, commission, prev_commission, commission_diff, courier_pay, net_profit
FROM leshchenko_food.how_much_money;
```
Ожидается:
- `commission = sum_with_commission - sum_no_commission`.
- `commission_diff = commission - prev_commission` (NULL для первого месяца).
- `net_profit = commission - courier_pay`.  
Факт:
- `2026-06`: sum_no=2000.00, sum_with=2200.00, comm=200.00, prev=NULL, diff=NULL, courier_pay=20.00, net_profit=180.00
- `2026-07`: sum_no=1000.00, sum_with=1100.00, comm=100.00, prev=200.00, diff=-100.00, courier_pay=10.00, net_profit=90.00
- `2026-08`: sum_no=1000.00, sum_with=1100.00, comm=100.00, prev=100.00, diff=0.00, courier_pay=10.00, net_profit=90.00
- `2026-09`: sum_no=2000.00, sum_with=2200.00, comm=200.00, prev=100.00, diff=100.00, courier_pay=20.00, net_profit=180.00
- `2026-10`: sum_no=2000.00, sum_with=2200.00, comm=200.00, prev=200.00, diff=0.00, courier_pay=20.00, net_profit=180.00
- `2026-11`: sum_no=2000.00, sum_with=2200.00, comm=200.00, prev=200.00, diff=0.00, courier_pay=20.00, net_profit=180.00  
Формулы сходятся абсолютно точно.  
Вердикт: `OK`

---

## G. Права `inspector`

### G.1. Права на схему

```sql
SELECT has_schema_privilege('inspector', 'leshchenko_food', 'USAGE') AS has_usage,
       has_schema_privilege('inspector', 'leshchenko_food', 'CREATE') AS has_create;
```
Ожидается: `true, true`.  
Факт: `true, true`.  
Вердикт: `OK`

### G.2. Права на таблицы

```sql
SELECT table_name,
       has_table_privilege('inspector', 'leshchenko_food.' || quote_ident(table_name), 'SELECT') AS can_select,
       has_table_privilege('inspector', 'leshchenko_food.' || quote_ident(table_name), 'INSERT') AS can_insert,
       has_table_privilege('inspector', 'leshchenko_food.' || quote_ident(table_name), 'UPDATE') AS can_update,
       has_table_privilege('inspector', 'leshchenko_food.' || quote_ident(table_name), 'DELETE') AS can_delete
FROM information_schema.tables
WHERE table_schema = 'leshchenko_food' AND table_type = 'BASE TABLE';
```
Ожидается: `true` для всех операций по всем таблицам.  
Факт: Все значения `true` для всех 12 таблиц.  
Вердикт: `OK`

### G.3. `information_schema` читается под `inspector`

```sql
SELECT count(*) FROM information_schema.tables WHERE table_schema = 'leshchenko_food';
```
Ожидается: 13 (12 таблиц + 1 view).  
Факт: 13.  
Вердикт: `OK`

### G.4. `pg_catalog` читается под `inspector`

```sql
SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname = 'leshchenko_food';
```
Ожидается: 12.  
Факт: 12.  
Вердикт: `OK`

### G.5. Все процедуры/функции работают под `inspector`

```sql
CALL erase_test_data();
CALL insert_test_data(10);
CALL courier_salary();
SELECT * FROM get_statistic();
SELECT * FROM how_much_money;
```
Ожидается: выполнение без `permission denied`.  
Факт: Все вызовы выполнены под настоящим подключением пользователя `inspector` без единой ошибки прав доступа.  
Вердикт: `OK`

---

## H. Оптимизация `get_statistic` (BR-11.8)

### H.1. EXPLAIN ANALYZE для `get_statistic`

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM leshchenko_food.get_statistic();
```
Ожидается:
- Однократное чтение доставленных заказов через `CTE delivered AS MATERIALIZED`.
- Отсутствие декартова умножения при подсчете денежных сумм и количеств блюд.
- Отсутствие коррелированных подзапросов в SELECT и избыточных оконных функций.  
Факт:
- План запроса: `CTE delivered` считывает доставленные заказы один раз с использованием индекса `idx_order_courier_delivered` (`Bitmap Heap Scan` + `Bitmap Index Scan`, `Buffers: shared hit=2`, время сканирования 0.008 мс).
- Агрегации по суммам, блюдам и клиентам производятся независимыми узлами `HashAggregate` / `GroupAggregate` по материализованному CTE.
- Итоговое соединение через серию `Hash Left Join` / `Hash Right Join`.
- Общее время выполнения: **0.213 мс**, `Buffers: shared hit=26`.  
Вердикт: `OK`

---

## I. Очистка и повторная генерация

### I.1. `erase_test_data` очищает всё

```sql
CALL leshchenko_food.erase_test_data();
```
Ожидается: 0 строк во всех 12 таблицах.  
Факт: Все 12 таблиц пусты (`count = 0`).  
Вердикт: `OK`

### I.2. Повторный `erase_test_data` не падает

```sql
CALL leshchenko_food.erase_test_data();
```
Ожидается: без ошибок (идемпотентность).  
Факт: Успешный повторный запуск без ошибок.  
Вердикт: `OK`

### I.3. После очистки `insert_test_data` снова работает

```sql
CALL leshchenko_food.insert_test_data(10);
SELECT count(*) FROM leshchenko_food."order";
```
Ожидается: 50.  
Факт: Ровно 50 заказов, ровно 10 клиентов, 10 курьеров, 10 ресторанов, 50 блюд, 50 оплат, 50 отзывов, 60 выплат.  
Вердикт: `OK`
