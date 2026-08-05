/// A single line item on an estimate or invoice.
class MockLineItem {
  const MockLineItem({required this.description, required this.amount});

  final String description;
  final double amount;
}
