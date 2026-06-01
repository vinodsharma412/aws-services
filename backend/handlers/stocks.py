"""Stocks Lambda — replaces FastAPI /stocks/* endpoints.

Routes:
  GET /stocks/search               ticker/company search
  GET /stocks/basic/{symbol}       fast quote
  GET /stocks/market/global        global indices snapshot
  GET /stocks/analyse/{symbol}     full technical + fundamental analysis
  GET /stocks/chart/{symbol}       OHLCV candlestick data
  GET /stocks/sentiment/{symbol}   news + Comprehend sentiment
  GET /stocks/screener             dividend/PE screener (reads DynamoDB cache)
  GET /stocks/financials/{symbol}  P&L, balance sheet, cash flow
  GET /stocks/portfolio            holdings + P&L
  GET /stocks/portfolio/insights   action recommendations
  POST /stocks/portfolio/transactions  record buy/sell/dividend
  DELETE /stocks/portfolio/transactions/{id}  remove transaction
  GET /stocks/watchlist            user watchlist
  POST /stocks/watchlist           add symbol
  DELETE /stocks/watchlist/{id}    remove symbol

AWS services used:
  - DynamoDB  (portfolio, watchlist, screener cache)
  - Comprehend  (ML sentiment scoring, 50K units/month free)
  - Translate  (translate product/news summaries to English)
  - X-Ray  (distributed tracing across all service calls)
  - CloudWatch  (automatic log ingestion)
  - AppConfig  (feature flags: COMPREHEND_ENABLED, TRANSLATE_ENABLED)
"""

import logging
import os
import sys

from aws_xray_sdk.core import patch_all, xray_recorder

patch_all()

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.crud import stock_dynamo
from app.services import sentiment_service, stock_service
from handlers._base import (
    bad_request,
    conflict,
    created,
    forbidden,
    get_body,
    get_current_role,
    get_current_user_id,
    get_current_username,
    get_method,
    get_path,
    get_path_params,
    get_qs,
    no_content,
    not_found,
    ok,
    server_error,
)

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def _txn_out(t: dict) -> dict:
    return {
        "id": t["txn_id"],
        "symbol": t["symbol"],
        "company_name": t.get("company_name", ""),
        "transaction_type": t["transaction_type"],
        "quantity": float(t["quantity"]),
        "price": float(t["price"]),
        "total_amount": float(t["total_amount"]),
        "brokerage": float(t.get("brokerage", 0)),
        "notes": t.get("notes"),
        "created_at": t.get("created_at"),
    }


def _wl_out(w: dict) -> dict:
    return {
        "id": w["wl_id"],
        "symbol": w["symbol"],
        "company_name": w.get("company_name"),
        "target_price": float(w["target_price"]) if w.get("target_price") else None,
        "stop_loss": float(w["stop_loss"]) if w.get("stop_loss") else None,
        "notes": w.get("notes"),
        "added_at": w.get("added_at"),
    }


@xray_recorder.capture("stocks")
def handler(event, context):
    method = get_method(event)
    path = get_path(event)
    path_params = get_path_params(event)
    qs = get_qs(event)
    user_id = get_current_user_id(event)

    if method == "OPTIONS":
        return ok({})

    try:
        # ── GET /stocks/search ────────────────────────────────────────────────
        if method == "GET" and "/search" in path:
            q = qs.get("q", "").strip()
            if not q:
                return bad_request("Query parameter 'q' is required")
            return ok(stock_service.search_stocks(q))

        # ── GET /stocks/basic/{symbol} ────────────────────────────────────────
        if method == "GET" and "/basic/" in path:
            symbol = path_params.get("symbol", path.split("/basic/")[-1]).upper()
            data = stock_service.get_basic_quote(symbol)
            if data.get("error"):
                return ok({"detail": data["error"]}, 502)
            return ok(data)

        # ── GET /stocks/market/global ─────────────────────────────────────────
        if method == "GET" and "/market/global" in path:
            return ok(stock_service.get_global_markets())

        # ── GET /stocks/analyse/{symbol} ──────────────────────────────────────
        if method == "GET" and "/analyse/" in path:
            symbol = path_params.get("symbol", path.split("/analyse/")[-1]).upper()
            sent = sentiment_service.analyze_sentiment(symbol)
            data = stock_service.get_stock_analysis(symbol, sent.get("score", 0.0))
            if data.get("error"):
                return ok({"detail": data["error"]}, 502)
            return ok(data)

        # ── GET /stocks/chart/{symbol} ────────────────────────────────────────
        if method == "GET" and "/chart/" in path:
            symbol = path_params.get("symbol", path.split("/chart/")[-1]).upper()
            period = qs.get("period", "1y")
            rows = stock_service.get_chart_data(symbol, period)
            if not rows:
                return not_found("No chart data available for this symbol")
            return ok(rows)

        # ── GET /stocks/sentiment/{symbol} ────────────────────────────────────
        if method == "GET" and "/sentiment/" in path:
            symbol = path_params.get("symbol", path.split("/sentiment/")[-1]).upper()
            name = stock_service.NSE_UNIVERSE.get(symbol, "")
            return ok(sentiment_service.analyze_sentiment(symbol, name))

        # ── GET /stocks/screener ──────────────────────────────────────────────
        if method == "GET" and path.endswith("/screener"):
            min_yield = float(qs.get("min_yield", 0.03))
            max_pe = float(qs.get("max_pe", 50.0))
            min_score = int(qs.get("min_score", 0))
            results = stock_service.screen_stocks(min_yield, max_pe, min_score)
            if min_score:
                results = [r for r in results if (r.get("score") or 0) >= min_score]
            return ok(results)

        # ── GET /stocks/financials/{symbol} ───────────────────────────────────
        if method == "GET" and "/financials/" in path:
            symbol = path_params.get("symbol", path.split("/financials/")[-1]).upper()
            data = stock_service.get_detailed_financials(symbol)
            if data.get("error"):
                return ok({"detail": data["error"]}, 502)
            return ok(data)

        # ── GET /stocks/portfolio/insights ────────────────────────────────────
        if method == "GET" and path.endswith("/insights"):
            raw_txns = stock_dynamo.get_transactions(user_id)
            txns = [
                type("T", (), {
                    "symbol": t["symbol"], "transaction_type": t["transaction_type"],
                    "quantity": float(t["quantity"]), "price": float(t["price"]),
                    "total_amount": float(t["total_amount"]), "brokerage": float(t.get("brokerage", 0)),
                })() for t in raw_txns
            ]
            pnl = stock_service.calculate_portfolio(txns)
            return ok(stock_service.generate_portfolio_insights(pnl["holdings"]))

        # ── GET /stocks/portfolio ─────────────────────────────────────────────
        if method == "GET" and path.endswith("/portfolio"):
            raw_txns = stock_dynamo.get_transactions(user_id)
            txns = [
                type("T", (), {
                    "symbol": t["symbol"], "transaction_type": t["transaction_type"],
                    "quantity": float(t["quantity"]), "price": float(t["price"]),
                    "total_amount": float(t["total_amount"]), "brokerage": float(t.get("brokerage", 0)),
                })() for t in raw_txns
            ]
            pnl = stock_service.calculate_portfolio(txns)
            return ok({
                "total_invested": pnl["total_invested"],
                "current_value": pnl["current_value"],
                "total_pnl": pnl["total_pnl"],
                "pnl_pct": pnl["pnl_pct"],
                "holdings": pnl["holdings"],
                "transactions": [_txn_out(t) for t in raw_txns],
            })

        # ── POST /stocks/portfolio/transactions ───────────────────────────────
        if method == "POST" and "/portfolio/transactions" in path and not path_params.get("txn_id"):
            body = get_body(event)
            symbol = body.get("symbol", "").upper()
            if not symbol:
                return bad_request("symbol is required")
            txn_type = body.get("transaction_type", "buy")
            quantity = float(body.get("quantity", 0))
            price = float(body.get("price", 0))
            brokerage = float(body.get("brokerage", 0))
            sign = -1 if txn_type == "sell" else 1
            total = abs(sign * quantity * price + brokerage)
            txn = stock_dynamo.create_transaction(
                user_id=user_id, symbol=symbol,
                company_name=body.get("company_name") or stock_service.NSE_UNIVERSE.get(symbol, ""),
                transaction_type=txn_type, quantity=quantity, price=price,
                total_amount=total, brokerage=brokerage, notes=body.get("notes"),
            )
            return created(_txn_out(txn))

        # ── DELETE /stocks/portfolio/transactions/{txn_id} ────────────────────
        txn_id = path_params.get("txn_id")
        if method == "DELETE" and txn_id and "/portfolio/transactions/" in path:
            txn = stock_dynamo.get_transaction(txn_id)
            if not txn:
                return not_found("Transaction not found")
            if txn.get("user_id") != user_id:
                return forbidden("Access denied")
            stock_dynamo.delete_transaction(txn_id)
            return no_content()

        # ── GET /stocks/watchlist ─────────────────────────────────────────────
        if method == "GET" and path.endswith("/watchlist"):
            items = stock_dynamo.get_watchlist(user_id)
            return ok([_wl_out(w) for w in items])

        # ── POST /stocks/watchlist ────────────────────────────────────────────
        if method == "POST" and path.endswith("/watchlist"):
            body = get_body(event)
            sym = body.get("symbol", "").upper()
            if not sym:
                return bad_request("symbol is required")
            if stock_dynamo.find_by_symbol(user_id, sym):
                return conflict(f"{sym} is already in your watchlist")
            item = stock_dynamo.add_to_watchlist(
                user_id=user_id, symbol=sym,
                company_name=body.get("company_name") or stock_service.NSE_UNIVERSE.get(sym, ""),
                target_price=body.get("target_price"),
                stop_loss=body.get("stop_loss"),
                notes=body.get("notes"),
            )
            return created(_wl_out(item))

        # ── DELETE /stocks/watchlist/{wl_id} ──────────────────────────────────
        wl_id = path_params.get("wl_id")
        if method == "DELETE" and wl_id:
            item = stock_dynamo.get_watchlist_item(wl_id)
            if not item:
                return not_found("Watchlist item not found")
            if item.get("user_id") != user_id:
                return forbidden("Access denied")
            stock_dynamo.remove_from_watchlist(wl_id)
            return no_content()

        return ok({"detail": "Route not found"}, 404)

    except Exception as e:
        logger.error("Stocks handler error: %s", e, exc_info=True)
        return server_error(str(e))
