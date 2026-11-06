# Обоснование ограничений физической модели FoodExpress

---

## 1. Enum-типы

Создано ровно 8 перечислимых типов данных (`CREATE TYPE ... AS ENUM`) в схеме `leshchenko_food` строго в соответствии с бизнес-требованиями `docs/company-rules.md`.

| Тип | Значения | BR | Обоснование |
|---|---|---|---|
| `restaurant_status` | `'активен'`, `'неактивен'` | BR-4.3 | Жизненный цикл ресторана-партнера сервиса. |
| `product_status` | `'доступно'`, `'нет_в_наличии'`, `'архив'` | BR-5.5 | Доступность блюда к заказу в меню ресторана. |
| `courier_status` | `'свободен'`, `'занят'`, `'на_доставке'`, `'уволен'` | BR-6.2 | Текущий статус занятости сотрудника курьерской службы. |
| `order_status` | `'создан'`, `'готовится'`, `'в_доставке'`, `'доставлен'`, `'отменён'` | BR-7.7 | Статусная модель жизненного цикла клиентского заказа. |
| `order_pay_status` | `'ожидает'`, `'оплачен'`, `'ошибка'` | BR-7.9, BR-8.7 | Агрегированный статус проведения оплаты заказа по попыткам. |
| `payment_status` | `'успех'`, `'ошибка'`, `'в_обработке'` | BR-8.2 | Статус конкретной финансовой попытки платежа. |
| `payment_type` | `'карта'`, `'наличные'`, `'безнал'` | BR-8.2 | Способ совершения платежа по конкретной попытке. |
| `review_entity_type` | `'блюдо'`, `'ресторан'`, `'заказ'` | BR-9.1 | Тип целевого объекта, оцениваемого клиентом в отзыве. |

---

## 2. Ловушки

### Ловушка 1: `payment` — неполная сущность

**Какие атрибуты добавлены в `payment` и почему (BR-8.2, BR-8.3):**
1. `payment_type leshchenko_food.payment_type NOT NULL` — хранит тип оплаты конкретной попытки (`карта`, `наличные`, `безнал`).
2. `amount numeric(14,2) NOT NULL` — сумма попытки транзакции (должна быть равна `order.total_amount`).
3. `transaction_id uuid NOT NULL UNIQUE DEFAULT exts.uuid_generate_v4()` — внешний уникальный идентификатор финансовой транзакции от платёжного провайдера. Реализован как UUID в соответствии с общим контрактом BR-11.1 («Все ID — UUID, генерируются на сервере через `exts.uuid_generate_v4()`»), что также обеспечивает идеальную валидацию приемочного теста B.4 (`column_name LIKE '%_id' AND data_type != 'uuid'` возвращает пусто).
4. `transaction_timestamp timestamp NOT NULL` — дата и время совершения транзакции в таймзоне сервера (BR-11.2).
5. `status leshchenko_food.payment_status NOT NULL` — статус проведения попытки платежа (`успех`, `ошибка`, `в_обработке`).

**Где хранится тип оплаты — `payment` или `order` (BR-8.6):**
Тип оплаты хранится **исключительно в таблице `payment`**.
По правилу BR-8.6 у одного заказа может быть несколько попыток оплаты разными способами (например, сначала неуспешная попытка картой, затем успешная наличными курьеру). Хранение типа оплаты в заказе привело бы к нарушению 1НФ и потере информации о способах предыдущих попыток.

---

### Ловушка 2: `order.address_id` — принадлежность клиенту (BR-7.4)

**Как обеспечено, что адрес доставки принадлежит клиенту:**
Обеспечено на уровне реляционной схемы с помощью **составного внешнего ключа (Composite Foreign Key)**:
```sql
CONSTRAINT fk_order_client_address FOREIGN KEY (client_id, address_id)
    REFERENCES leshchenko_food.client_address (client_id, address_id)
    ON DELETE NO ACTION
```
В таблице `client_address` первичным ключом является пара `(client_id, address_id)`. Ссылка внешнего ключа из `"order"` на составной ключ `client_address(client_id, address_id)` на уровне ядра СУБД делает физически невозможной вставку заказа с адресом, не привязанным к клиенту, оформляющему заказ. Дополнительно сохранен классический FK на `address(address_id)`.

---

### Ловушка 3: `order_structure` — один ресторан в заказе (BR-7.3)

**Как обеспечено, что все блюда из `order.restaurant_id`:**
Обеспечено с помощью транзакционного отложенного проверочного триггера `check_order_integrity()`:
```sql
CREATE CONSTRAINT TRIGGER trg_check_order_integrity_structure
AFTER INSERT OR UPDATE OR DELETE ON leshchenko_food.order_structure
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION leshchenko_food.check_order_integrity();
```
Триггер проверяет:
```sql
IF EXISTS (
    SELECT 1
    FROM leshchenko_food.order_structure os
    JOIN leshchenko_food.product p ON p.product_id = os.product_id
    WHERE os.order_id = v_order_id AND p.restaurant_id != v_order.restaurant_id
) THEN
    RAISE EXCEPTION 'BR-7.3: Все блюда в заказе должны принадлежать ресторану заказа' USING ERRCODE = '23514';
END IF;
```
Аналогичный отложенный триггер установлен на `product` при изменении `restaurant_id`. За счет отложенности (`DEFERRABLE INITIALLY DEFERRED`) проверка выполняется в момент фиксации транзакции (COMMIT), позволяя атомарно формировать заказ и его позиции.

---

### Ловушка 4: `review` — полиморфизм (BR-9.1)

**Как реализована валидность `review.entity_id`:**
Реализован гибридный подход: концептуальная схема сохранена с полиморфными полями `entity_id uuid` и `entity_type review_entity_type` (без изменения ERD и без создания 3 отдельных суррогатных таблиц отзывов), а бизнес-целостность строго защищена:
1. Ограничение `CONSTRAINT fk_review_order_client FOREIGN KEY (order_id, client_id) REFERENCES leshchenko_food."order"(order_id, client_id)` гарантирует, что отзыв оставляет именно тот клиент, который сделал этот заказ (BR-9.2).
2. Ограничение `CONSTRAINT uq_review_order_entity UNIQUE (order_id, entity_type, entity_id)` гарантирует, что в рамках одного заказа клиент может оставить не более одного отзыва на каждый конкретный объект (BR-9.5).
3. Отложенный триггер `check_order_integrity()` при COMMIT транзакции проверяет принадлежность цели отзыва заказу:
   - если `entity_type = 'заказ'`, то `entity_id = order_id`;
   - если `entity_type = 'ресторан'`, то `entity_id = order.restaurant_id`;
   - если `entity_type = 'блюдо'`, то `entity_id` обязан присутствовать в позициях заказа `order_structure` по данному `order_id`.
При нарушении выбрасывается исключение с кодом `23514` и ссылкой на `BR-9.2`.

---

## 3. CHECK-ограничения

| Таблица | Столбец | Условие | BR | Обоснование |
|---|---|---|---|---|
| `client` | `login` | `length(btrim(login)) > 0` | BR-2.1, BR-11.3 | Логин обязателен и не может быть пустой строкой из пробелов. |
| `client` | `password` | `password ~ '^[0-9a-f]{32}$'` | BR-2.3 | Пароль хранится в виде 32-символьного MD5-хэша в нижнем регистре. |
| `client` | `phone_number` | `length(btrim(phone_number)) > 0` | BR-2.1, BR-11.3 | Телефон клиента обязателен. |
| `address` | `street` | `length(btrim(street)) > 0` | BR-3.1, BR-11.3 | Название улицы обязательно. |
| `address` | `house_number` | `length(btrim(house_number)) > 0` | BR-3.1, BR-11.3 | Номер дома обязателен. |
| `address` | `apartment_office` | `apartment_office IS NULL OR length(btrim(apartment_office)) > 0` | BR-3.2, BR-11.3 | Номер квартиры/офиса опционален, но при наличии не может быть пробельной строкой. |
| `restaurant` | `restaurant_name` | `length(btrim(restaurant_name)) > 0` | BR-4.1, BR-11.3 | Название ресторана обязательно. |
| `restaurant` | `description` | `length(btrim(description)) > 0` | BR-4.1, BR-11.3 | Описание ресторана обязательно. |
| `restaurant` | `company_details` | `length(btrim(company_details)) > 0` | BR-4.1, BR-4.5 | Юридические реквизиты ресторана обязательны. |
| `restaurant` | `work_start, work_end` | `work_end > work_start` | BR-4.4 | Время закрытия ресторана строго позже времени открытия. |
| `restaurant` | `rating` | `rating IS NULL OR (rating >= 0.00 AND rating <= 5.00)` | BR-4.2, BR-9.7 | Агрегированный рейтинг ресторана лежит в диапазоне 0..5 либо NULL при отсутствии отзывов. |
| `courier` | `FIO` | `length(btrim(FIO)) > 0` | BR-6.1, BR-11.3 | ФИО курьера обязательно. |
| `courier` | `phone_number` | `length(btrim(phone_number)) > 0` | BR-6.1, BR-11.3 | Телефон курьера обязателен. |
| `courier` | `coefficient` | `coefficient >= 0.1 AND coefficient <= 0.5` | BR-6.4 | Коэффициент курьера ограничен диапазоном 0.1..0.5. |
| `courier` | `hire_date, dismissal_date` | `dismissal_date IS NULL OR dismissal_date >= hire_date` | BR-6.3 | Дата увольнения не может предшествовать дате найма. |
| `courier` | `status, dismissal_date` | `(status = 'уволен' AND dismissal_date IS NOT NULL) OR (status != 'уволен' AND dismissal_date IS NULL)` | BR-6.3, BR-11.3 | Уволенный курьер обязан иметь дату увольнения, работающий курьер не имеет даты увольнения. |
| `courier_pay` | `year` | `year >= 1` | BR-10.3, BR-11.6 | Номер года является корректным положительным числом. |
| `courier_pay` | `month` | `month >= 1 AND month <= 12` | BR-10.3, BR-11.6 | Номер месяца находится в диапазоне 1..12. |
| `courier_pay` | `amount` | `amount >= 0.00` | BR-10.4 | Сумма заработной платы курьера неотрицательна. |
| `courier_pay` | `coefficient_used` | `coefficient_used >= 0.1 AND coefficient_used <= 0.5` | BR-6.4, BR-10.2 | Примененный коэффициент соответствует правилам начисления. |
| `product_category`| `product_category_name`| `length(btrim(product_category_name)) > 0` | BR-5.7, BR-11.3 | Название категории блюд обязательно. |
| `product` | `product_name` | `length(btrim(product_name)) > 0` | BR-5.2, BR-11.3 | Название блюда обязательно. |
| `product` | `price` | `price >= 0.00` | BR-5.3 | Цена блюда не может быть отрицательной. |
| `product` | `rating` | `rating IS NULL OR (rating >= 0.00 AND rating <= 5.00)` | BR-5.4, BR-9.7 | Агрегированный рейтинг блюда лежит в диапазоне 0..5 либо NULL при отсутствии отзывов. |
| `product` | `description` | `length(btrim(description)) > 0` | BR-5.2, BR-11.3 | Описание блюда обязательно. |
| `product` | `photo_url` | `photo_url IS NULL OR length(btrim(photo_url)) > 0` | BR-5.6, BR-11.3 | Фотография блюда опциональна. |
| `"order"` | `order_amount` | `order_amount >= 0.00` | BR-7.10 | Сумма стоимости блюд заказа неотрицательна. |
| `"order"` | `commission` | `commission = round(order_amount * 0.10, 2)` | BR-1.4, BR-7.10 | Комиссия сервиса составляет ровно 10% от стоимости блюд. |
| `"order"` | `total_amount` | `total_amount = order_amount + commission` | BR-1.5, BR-7.10 | Итоговая сумма заказа равна сумме стоимости блюд и комиссии. |
| `"order"` | `total_amount` | `total_amount >= 1000.00` | BR-1.8, BR-7.11 | Минимальная сумма заказа составляет не менее 1000 ₽. |
| `"order"` | `order_timestamp, delivery_timestamp` | `delivery_timestamp IS NULL OR delivery_timestamp >= order_timestamp` | BR-7.13 | Время доставки не может быть раньше времени оформления заказа. |
| `"order"` | `status, delivery_timestamp` | `(status = 'доставлен' AND delivery_timestamp IS NOT NULL) OR (status != 'доставлен' AND delivery_timestamp IS NULL)` | BR-7.12, BR-11.3 | Время доставки заполняется тогда и только тогда, когда заказ доставлен. |
| `"order"` | `description` | `length(btrim(description)) > 0` | BR-7.1, BR-11.3 | Описание/комментарий к заказу обязательно. |
| `order_structure` | `quantity` | `quantity > 0` | BR-7.15 | Количество позиций в заказе строго положительно (допускаются дробные величины). |
| `order_structure` | `unit_price` | `unit_price >= 0.00` | BR-7.10 | Снимок цены позиции в заказе неотрицателен. |
| `payment` | `amount` | `amount >= 0.00` | BR-8.2 | Сумма попытки оплаты неотрицательна. |
| `review` | `rating` | `rating >= 1.0 AND rating <= 5.0` | BR-9.4 | Оценка в отзыве клиента лежит в диапазоне от 1 до 5. |
| `review` | `description` | `length(btrim(description)) > 0` | BR-9.3, BR-11.3 | Текст отзыва клиента обязателен. |
| `review` | `photo_url` | `photo_url IS NULL OR length(btrim(photo_url)) > 0` | BR-9.3, BR-11.3 | Фотография к отзыву опциональна. |

---

## 4. UNIQUE-ограничения

| Таблица | Столбцы | BR | Обоснование |
|---|---|---|---|
| `client` | `login` | BR-2.2 | Логин клиента уникален в системе. |
| `client` | `phone_number` | BR-2.2 | Номер телефона клиента уникален в системе. |
| `address` | `street, house_number, apartment_office` (с `NULLS NOT DISTINCT`) | BR-3.1, BR-3.3, BR-3.4 | Единственность записи физического адреса, в том числе для частных домов с `apartment_office IS NULL`. |
| `restaurant` | `address_id` | BR-3.3 | У каждого ресторана свой уникальный физический адрес; два ресторана не могут делить адрес. |
| `"order"` | `order_id, client_id` | BR-9.2 | Обеспечивает возможность ссылки внешнего ключа `review(order_id, client_id)` для гарантии авторства отзыва. |
| `review` | `order_id, entity_type, entity_id` | BR-9.5 | В рамках одного заказа клиент может оставить не более одного отзыва на конкретный объект. |
| `payment` | `transaction_id` | BR-8.3 | Внешний идентификатор финансовой транзакции платежной системы строго уникален. |
| `payment` | `order_id WHERE status = 'успех'` (частичный UNIQUE) | BR-8.1 | У заказа может быть несколько попыток оплаты, но ровно одна из них успешная. |

---

## 5. FK-ограничения

| Таблица | Столбцы | → Таблица | BR | Обоснование |
|---|---|---|---|---|
| `client_address` | `client_id` | `client(client_id)` | BR-2.4 | Привязка адреса к клиенту (M:N). `ON DELETE NO ACTION`. |
| `client_address` | `address_id` | `address(address_id)` | BR-2.4 | Ссылка на существующий физический адрес. `ON DELETE NO ACTION`. |
| `restaurant` | `address_id` | `address(address_id)` | BR-3.3 | Адрес местонахождения ресторана. `ON DELETE NO ACTION`. |
| `courier_pay` | `courier_id` | `courier(courier_id)` | BR-10.1 | Выплата привязана к конкретному курьеру. `ON DELETE NO ACTION`. |
| `product` | `product_category_id` | `product_category(product_category_id)` | BR-5.1 | Каждое блюдо принадлежит ровно одной категории. `ON DELETE NO ACTION`. |
| `product` | `restaurant_id` | `restaurant(restaurant_id)` | BR-5.1 | Каждое блюдо принадлежит ровно одному ресторану. `ON DELETE NO ACTION`. |
| `"order"` | `client_id, address_id` | `client_address(client_id, address_id)` | BR-7.4 | Адрес доставки обязан принадлежать клиенту, оформляющему заказ. `ON DELETE NO ACTION`. |
| `"order"` | `address_id` | `address(address_id)` | BR-7.4 | Прямая реляционная связь с физическим адресом доставки. `ON DELETE NO ACTION`. |
| `"order"` | `client_id` | `client(client_id)` | BR-7.2 | Заказ оформляется конкретным клиентом. `ON DELETE NO ACTION`. |
| `"order"` | `courier_id` | `courier(courier_id)` | BR-7.5 | Доставку заказа выполняет курьер. `ON DELETE NO ACTION`. |
| `"order"` | `restaurant_id` | `restaurant(restaurant_id)` | BR-7.2 | Заказ формируется в конкретном ресторане. `ON DELETE NO ACTION`. |
| `order_structure`| `order_id` | `"order"(order_id)` | BR-7.14 | Позиция заказа входит в конкретный заказ. `ON DELETE NO ACTION`. |
| `order_structure`| `product_id` | `product(product_id)` | BR-7.14 | Позиция заказа указывает на блюдо из меню. `ON DELETE NO ACTION`. |
| `payment` | `order_id` | `"order"(order_id)` | BR-8.1 | Попытка оплаты привязана к оплачиваемому заказу. `ON DELETE NO ACTION`. |
| `review` | `order_id, client_id` | `"order"(order_id, client_id)` | BR-9.2 | Отзыв привязан к заказу и клиенту, выполнившему заказ. `ON DELETE NO ACTION`. |

Все внешние ключи настроены с `ON DELETE NO ACTION` (без каскадного удаления), что гарантирует сохранение истории заказов, оплат и адресов в соответствии с BR-3.5.

---

## 6. NOT NULL (только бизнес-обязательные)

| Таблица | Столбец | BR | Обоснование |
|---|---|---|---|
| `restaurant` | `company_details` | BR-4.1, BR-4.5 | Сервис работает только с официально зарегистрированными юридическими лицами. |
| `restaurant` | `work_start, work_end` | BR-4.4 | Ресторан обязан публиковать график работы для клиентов и курьеров. |
| `courier` | `hire_date` | BR-6.1 | Дата найма сотрудника обязательна для кадрового и зарплатного учета. |
| `"order"` | `order_timestamp` | BR-7.1 | Момент оформления заказа фиксируется обязательно для расчетов и SLA. |
| `"order"` | `status, pay_status` | BR-7.7, BR-7.9 | Заказ в любой момент времени имеет определенный операционный и платежный статус. |
| `payment` | `transaction_timestamp` | BR-8.2 | Время проведения платежа обязательно для финансового аудита. |
| `review` | `review_timestamp` | BR-9.3 | Время публикации отзыва обязательно для хронологии. |
| `order_structure` | `unit_price` | BR-7.10 | Фиксация исторической стоимости позиции на момент покупки обязательна. |

---

## 7. NULL (осознанно разрешено)

| Таблица | Столбец | BR | Почему NULL |
|---|---|---|---|
| `address` | `apartment_office` | BR-3.2, BR-11.3 | Бывают частные дома, коттеджи и отдельные строения без номеров квартир или офисов. |
| `courier` | `dismissal_date` | BR-6.3, BR-11.3 | Работающий курьер не имеет даты увольнения; поле заполняется только при переводе в статус `'уволен'`. |
| `product` | `photo_url` | BR-5.6, BR-11.3 | Фотография блюда является опциональной ссылкой в меню. |
| `product` | `rating` | BR-5.4, BR-9.7 | До появления первых отзывов на блюдо его средний рейтинг не определен (`NULL`). |
| `restaurant` | `rating` | BR-4.2, BR-9.7 | До появления первых отзывов на ресторан его средний рейтинг не определен (`NULL`). |
| `"order"` | `delivery_timestamp` | BR-7.12, BR-11.3 | Время окончания доставки отсутствует у заказов, находящихся в процессе обработки и доставки. |
| `review` | `photo_url` | BR-9.3, BR-11.3 | Прикрепление фотографии к отзыву является добровольным действием клиента. |

---

## 8. DEFAULT и GENERATED

| Таблица | Столбец | Что | Обоснование |
|---|---|---|---|
| Все PK | `*_id` | `DEFAULT exts.uuid_generate_v4()` | BR-11.1: серверная генерация глобальных уникальных идентификаторов. |
| `courier` | `coefficient` | `DEFAULT 0.1` | BR-6.5: начальный коэффициент курьера при приеме на работу равен 0.1. |
| `payment` | `transaction_id` | `DEFAULT exts.uuid_generate_v4()` | BR-8.3, BR-11.1: уникальный финансовый идентификатор провайдера. |
| `"order"` | `commission` | Обычный столбец + CHECK | Выбран обычный столбец с ограничением `CHECK (commission = round(order_amount * 0.10, 2))` для 100% совместимости с ERD и возможностью независимой сериализации/десериализации бэкапа без конфликтов с вычисляемыми генераторами. |
| `"order"` | `total_amount` | Обычный столбец + CHECK | Выбран обычный столбец с ограничением `CHECK (total_amount = order_amount + commission)` и `CHECK (total_amount >= 1000.00)` для полной совместимости со структурой ERD и надежной проверки согласованности. |
| `order_structure` | `unit_price` | BEFORE INSERT триггер `set_order_line_price()` | Если цена позиции не передана явно, триггер автоматически подставляет текущую цену из `product.price`. Если цена передана явно (как делает генератор), сохраняется переданное значение. Это гарантирует неизменность исторической стоимости чека при последующих изменениях цен в меню (BR-7.10). |

---

## 9. Нормализация (3НФ)

Все 12 таблиц физической схемы находятся в **третьей нормальной форме (3НФ)**:

1. **1НФ**: Все атрибуты атомарны. Отсутствуют повторяющиеся группы и массивы в полях сущностей. Все таблицы обладают явно определенными первичными ключами.
2. **2НФ**: Все таблицы находятся в 1НФ, и каждый неключевой атрибут функционально полно зависит от всего первичного ключа:
   - В таблицах с составными первичными ключами:
     - `client_address (client_id, address_id)` — связь M:N без дополнительных атрибутов.
     - `order_structure (order_id, product_id)` — количество `quantity` и снимок цены `unit_price` относятся именно к связке конкретного заказа и конкретного блюда.
     - `courier_pay (year, month, courier_id)` — сумма выплаты `amount` и примененный коэффициент `coefficient_used` зависят от полного составного ключа года, месяца и курьера.
3. **3НФ**: Все таблицы находятся во 2НФ, и отсутствуют транзитивные зависимости между неключевыми атрибутами:
   - Адрес клиента нормализован через отдельную таблицу `address` и таблицу связей `client_address`.
   - Ресторан вынесен в отдельную таблицу `restaurant`, блюдо связано с категорией и рестораном внешними ключами.
   - Оплата денормализована по типам: тип оплаты хранится в `payment`, а не в `order`.

**Обоснование контролируемой денормализации:**
- `order.commission` и `order.total_amount` представляют собой вычисляемые финансовые итоги. Их наличие в таблице `"order"` зафиксировано концептуальной схемой ERD. Строгая функциональная зависимость контролируется ограничениями `CHECK (commission = round(order_amount * 0.10, 2))` и `CHECK (total_amount = order_amount + commission)`.
- `product.rating` и `restaurant.rating` — агрегированные показатели, вычисляемые как среднее арифметическое оценок клиентов по отзывам. Они хранятся непосредственно в сущностях `product` и `restaurant` для обеспечения высокой производительности чтения каталога меню и витрины ресторанов при миллионах запросов. Консистентность агрегата гарантируется триггером `rating_change` при любых операциях INSERT, UPDATE и DELETE в таблице `review` (BR-9.6, BR-9.7).
- `review.entity_id` и `review.entity_type` реализуют полиморфную связь в соответствии с концептуальной схемой ERD. Реляционная целостность поддержана внешним ключом на заказ/клиента и комплексным отложенным триггером `check_order_integrity()`.
