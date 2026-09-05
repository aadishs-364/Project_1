# Business Insights

Every number here comes from the queries in `sql/09_business_reports.sql`, run
against the seed dataset. The raw tables are in `output/report_pack.md` and the
per-report CSVs in `output/`. Regenerate everything with
`python tools/run_project.py`.

**Period covered:** January 2024 to August 2026 (32 months)
**Analysis date:** 4 September 2026
**Currency:** INR

---

## Headline numbers

| Metric | Value |
| --- | --- |
| Orders placed | 1,391 |
| Orders completed | 1,165 |
| Revenue (completed only) | 1,03,94,943 |
| Gross profit | 43,19,793 |
| Gross margin | 41.6% |
| Average order value | 8,923 |
| Customers who bought | 110 of 120 registered |
| Cancellation rate | 5.18% |
| Return rate | 7.76% |

"Revenue" means completed orders only throughout. `PLACED` and `SHIPPED` orders
are not money in the bank yet, and `CANCELLED` / `RETURNED` orders never will
be.

---

## 1. Volume is growing, but the average order is shrinking

Comparing January to August across three years, so the incomplete tail of 2026
does not distort the picture:

| Jan-Aug | Orders | Revenue | Average order value |
| --- | --- | --- | --- |
| 2024 | 210 | 21,66,874 | 10,318 |
| 2025 | 289 | 25,44,270 | 8,804 |
| 2026 | 310 | 25,39,852 | 8,193 |

Order volume is up 47.6% over two years. Revenue is up only 17.2%, and between
2025 and 2026 it went slightly backwards (-0.2%) despite 7.3% more orders.

The gap is entirely average order value, which has fallen 20.6% in two years.
Growth is currently being bought with more transactions rather than better
ones, and the trend line is heading towards more orders for the same money.
Basket-building - bundles, cross-sell, free-shipping thresholds - is worth more
here than another push on traffic.

**Caveat on the last month:** August 2026 shows 26 completed orders against 51
placed. The other 20 are still `SHIPPED` or `PLACED`. The month is not weak, it
is simply not finished settling, and it should not be read as a decline.

October is reliably the strongest month of the year (44 orders in 2024, 62 in
2025), which is what you would expect from a festive-season peak.

---

## 2. The catalogue is top-heavy in revenue and bottom-heavy in margin

| Category | Revenue share | Gross margin |
| --- | --- | --- |
| Electronics | 56.0% | 34.7% |
| Fashion | 16.4% | 53.4% |
| Home & Kitchen | 11.5% | 42.3% |
| Sports & Fitness | 8.5% | 49.3% |
| Beauty & Personal Care | 5.0% | 55.4% |
| Books & Stationery | 2.6% | 60.6% |

Electronics brings in more than half the revenue at the *worst* margin in the
catalogue. Books, Beauty and Fashion carry the best margins and only 24% of
revenue between them.

The single biggest product, the Aurora 27in 4K Monitor, is the clearest example:
14,92,216 of revenue at 22.2% margin. It contributes 14.4% of revenue but only
7.7% of gross profit.

This is not an argument for dropping Electronics - it is what brings customers
in. It is an argument for attaching a high-margin item to every Electronics
order. The basket analysis in `04_joins.sql` already shows accessories pairing
naturally with them.

Revenue concentration is real but not extreme: 21 of the 40 products that sell
at all (52.5% of them) account for 80% of revenue. That is a fatter tail than
the classic 80/20, and it means there is no small set of products the business
can afford to run out of.

---

## 3. Six products are out of stock, and two of them are the top sellers

Six active products have zero stock and recorded demand in the last 90 days:

| Product | Trailing revenue | Units last 90 days |
| --- | --- | --- |
| Aurora 27in 4K Monitor | 14,92,216 | 5 |
| Aurora 24in FHD Monitor | 7,45,314 | 4 |
| Vertex Wireless Mouse | 2,36,200 | 17 |
| RallyPro Badminton Racket | 1,48,405 | 4 |
| Larkspur Leather Wallet | 1,40,383 | 10 |
| Meadow Microfibre Pillow (2 pack) | 95,752 | 14 |

Together these represent 28,58,270 of historical revenue - 27.5% of the total -
with nothing on the shelf. The two Aurora monitors are the number one and
number four products by revenue.

This is very likely part of the average-order-value decline in section 1: the
two highest-priced items in the catalogue cannot be bought.

Meanwhile, three products have never sold a single unit, with 1,28,800 of cost
sitting in them (a cookware set and an electric kettle carry almost all of it).
That is capital funding stock nobody wants while the best sellers are empty.

---

## 4. The business runs on repeat buyers

| Buyer type | Customers | Share of customers | Share of revenue |
| --- | --- | --- | --- |
| Repeat (5+ orders) | 71 | 59.2% | 91.4% |
| Occasional (2-4) | 26 | 21.7% | 7.8% |
| One-time | 10 | 8.3% | 0.8% |
| Never purchased | 13 | 10.8% | 0.0% |

Split by order sequence rather than by customer, the same story: 90.0% of
revenue comes from repeat orders, only 10.0% from a customer's first purchase.

Retention holds up well. Of customers acquired in any given month, 37.4% order
again the following month, and by month six the figure is still 35.0%. The
curve is flat rather than decaying, which means once someone buys twice they
tend to keep buying.

The RFM segmentation in `06_advanced_analytics.sql` sharpens this:

| Segment | Customers | Revenue | Share |
| --- | --- | --- | --- |
| Champions | 26 | 58,03,389 | 55.8% |
| Loyal | 26 | 25,91,977 | 24.9% |
| Hibernating | 37 | 9,34,752 | 9.0% |
| At Risk - was valuable | 5 | 5,32,795 | 5.1% |
| Cannot Lose Them | 2 | 2,77,300 | 2.7% |
| New / Promising | 7 | 1,82,724 | 1.8% |
| Needs Attention | 4 | 72,007 | 0.7% |

26 customers - under a quarter of the buying base - produce 55.8% of revenue.
The seven customers in "At Risk" and "Cannot Lose Them" have historically spent
8,10,095 between them and have gone quiet. Seven phone calls is a cheap
intervention for that much revenue at risk.

At the other end, 13 registered accounts have never placed an order. That is a
10.8% leak in the signup funnel and a straightforward win-back campaign.

---

## 5. Discounting is buying nothing

Average units per order line, by discount band:

| Discount band | Order lines | Avg units per line | Gross margin |
| --- | --- | --- | --- |
| 0% (full price) | 1,449 | 1.48 | 43.9% |
| 1-5% | 364 | 1.47 | 39.8% |
| 6-10% | 323 | 1.52 | 39.9% |
| 11-15% | 209 | 1.48 | 33.3% |
| 16%+ | 140 | 1.39 | 34.9% |

If discounts were driving volume, units per line would climb as the discount
deepens. It does not - it is flat at roughly 1.5 units across every band, and it
actually *falls* in the deepest band.

What does move is margin, from 43.9% at full price down to 33.3%.

40.5% of revenue was discounted, and 4,79,826 of margin was given away to
produce no measurable lift in basket size. On this evidence the discount budget
would do more work redirected into the stock gaps in section 3.

One honest limitation: this is observational. Discounts may have been applied to
products that were harder to sell in the first place, so the comparison is not
a controlled one. The right follow-up is a holdout test, not a bigger query.

---

## 6. 14.1% of order value never converts to cash

| Loss type | Value |
| --- | --- |
| Cancelled orders | 8,29,458 |
| Returned orders | 9,53,717 |
| **Total lost order value** | **17,83,175** |

That is 14.1% of the 1,26,19,086 of order value written across all statuses.
Loss rates are not evenly spread:

| Category | Loss rate |
| --- | --- |
| Home & Kitchen | 16.0% |
| Electronics | 14.9% |
| Fashion | 12.9% |
| Books & Stationery | 12.2% |
| Beauty & Personal Care | 11.2% |
| Sports & Fitness | 11.1% |

Electronics loses the most in absolute terms (10,66,995) because it is the
largest category, but Home & Kitchen has the worst *rate*. High-value returns
are expensive twice over - the sale is lost and the item comes back used.

On the payments side, 6.24% of the 1,586 attempts fail. The failure rate splits
clearly by method:

| Method | Attempts | Failure rate |
| --- | --- | --- |
| COD | 194 | 8.8% |
| Net banking | 186 | 8.6% |
| UPI | 494 | 5.9% |
| Credit card | 364 | 5.8% |
| Debit card | 184 | 5.4% |
| Wallet | 164 | 3.7% |

COD and net banking fail at more than twice the rate of wallet payments.
Nudging customers towards UPI and wallets at checkout is a low-effort recovery.

---

## 7. Where the customers are

Jaipur is the largest market by revenue (11,68,982 from 12 customers), but on
revenue *per customer* the leaders are different:

| City | Customers | Revenue | Revenue per customer |
| --- | --- | --- | --- |
| Lucknow | 6 | 8,26,115 | 1,37,686 |
| Kolkata | 5 | 6,63,075 | 1,32,615 |
| Bhubaneswar | 7 | 9,23,711 | 1,31,959 |
| Kochi | 7 | 8,60,097 | 1,22,871 |
| Jaipur | 12 | 11,68,982 | 97,415 |

Bhubaneswar, Kochi and Lucknow are punching well above their customer count.
Indore is the outlier in the other direction: 6 customers producing 11,999
each, roughly a tenth of Lucknow.

Channel mix is healthy and evenly profitable - mobile app 36.8% of revenue at
43.2% margin, web 31.9% at 40.0%, store 17.2%, marketplace 14.0%. Web carries
the highest average order value (9,825 against the app's 8,058), so the app is
winning on frequency and the web on basket size.

---

## What I would do next

1. **Reorder the six stocked-out products**, starting with the two Aurora
   monitors. This is the highest-value and lowest-effort item on the list.
2. **Clear the 1,28,800 of never-sold stock** and recycle the capital into (1).
3. **Stop or shrink the discount programme** pending a proper holdout test. It
   is currently costing 4,79,826 of margin for no measurable volume lift.
4. **Contact the seven "At Risk" and "Cannot Lose Them" customers.** 8,10,095
   of historical spend has gone quiet.
5. **Attach a high-margin item to every Electronics order.** Electronics is
   56% of revenue at the worst margin in the catalogue; the product-pair
   analysis already shows which accessories sell alongside it.
6. **Investigate Home & Kitchen returns**, which run at 16.0% against a 11-13%
   baseline elsewhere.

## Limitations

- The dataset is simulated (`tools/generate_seed_data.py`, fixed seed). The
  relationships in it are the ones I built in, so this reads as a worked
  analytical exercise rather than a finding about a real market.
- There is no marketing spend or traffic data, so nothing here can be turned
  into a customer acquisition cost or a return on ad spend.
- Section 5 is observational, not experimental, as noted there.
- 120 customers is a small base. The RFM quintiles hold roughly 22 customers
  each, so individual segment movements are noisy.
