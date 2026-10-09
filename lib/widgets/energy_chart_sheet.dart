import 'dart:math';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/plug_models.dart';

class EnergyChartSheet extends StatelessWidget {
  final PlugEnergyStats stats;

  const EnergyChartSheet({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxConsume = stats.last7DaysList.isEmpty
        ? 1.0
        : stats.last7DaysList.map((e) => e.consumeKWh).reduce(max);
    final maxY = max(maxConsume * 1.25, 1.0);

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '电量统计与分析',
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // 统计概览四大卡片
              Row(
                children: [
                  Expanded(child: _buildStatCard('今日用电', '${stats.todayKWh} 度', Colors.blue)),
                  const SizedBox(width: 12),
                  Expanded(child: _buildStatCard('本周用电', '${stats.weekKWh} 度', Colors.teal)),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _buildStatCard('本月用电', '${stats.monthKWh} 度', Colors.deepPurple)),
                  const SizedBox(width: 12),
                  Expanded(child: _buildStatCard('上月用电', '${stats.lastMonthKWh} 度', Colors.indigo)),
                ],
              ),
              const SizedBox(height: 24),

              // 近 7 天趋势柱状图
              Text(
                '近 7 天每日用电趋势 (度)',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Container(
                height: 200,
                padding: const EdgeInsets.only(top: 16, right: 16),
                decoration: BoxDecoration(
                  color: theme.cardColor,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: BarChart(
                  BarChartData(
                    alignment: BarChartAlignment.spaceAround,
                    maxY: maxY,
                    barTouchData: BarTouchData(
                      touchTooltipData: BarTouchTooltipData(
                        getTooltipItem: (group, groupIndex, rod, rodIndex) {
                          if (groupIndex < 0 || groupIndex >= stats.last7DaysList.length) return null;
                          final item = stats.last7DaysList[groupIndex];
                          return BarTooltipItem(
                            '${item.dateStr}\n${rod.toY.toStringAsFixed(3)} 度',
                            const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                          );
                        },
                      ),
                    ),
                    titlesData: FlTitlesData(
                      show: true,
                      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 38,
                          getTitlesWidget: (value, meta) {
                            return Text(
                              value.toStringAsFixed(1),
                              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                            );
                          },
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          getTitlesWidget: (value, meta) {
                            final idx = value.toInt();
                            if (idx >= 0 && idx < stats.last7DaysList.length) {
                              final d = stats.last7DaysList[idx].date;
                              return Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  DateFormat('MM/dd').format(d),
                                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                                ),
                              );
                            }
                            return const SizedBox.shrink();
                          },
                        ),
                      ),
                    ),
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      horizontalInterval: maxY / 4,
                      getDrawingHorizontalLine: (value) => FlLine(
                        color: Colors.grey.withValues(alpha: 0.15),
                        strokeWidth: 1,
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                    barGroups: List.generate(stats.last7DaysList.length, (i) {
                      final item = stats.last7DaysList[i];
                      return BarChartGroupData(
                        x: i,
                        barRods: [
                          BarChartRodData(
                            toY: item.consumeKWh,
                            color: theme.colorScheme.primary,
                            width: 14,
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                          ),
                        ],
                      );
                    }),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // 最近小时级明细
              Text(
                '最近用电记录 (按小时)',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              if (stats.rawHourlyList.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: Text('暂无历史用电记录', style: TextStyle(color: Colors.grey))),
                )
              else
                ...stats.rawHourlyList.take(24).map((h) {
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: theme.cardColor,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.access_time, size: 16, color: Colors.grey),
                            const SizedBox(width: 8),
                            Text(
                              DateFormat('yyyy-MM-dd HH:mm').format(h.endTime),
                              style: const TextStyle(fontSize: 13),
                            ),
                          ],
                        ),
                        Text(
                          '${h.consumeKWh.toStringAsFixed(3)} 度 (${h.consumeWh.toStringAsFixed(1)} Wh)',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatCard(String title, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: color.withValues(alpha: 0.8), fontSize: 13)),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
