/// A technician profile.
///
/// Fields mirror the eventual `technicians` Supabase table so the model can
/// be swapped for a real one without touching the UI.
class MockTechnician {
  const MockTechnician({
    required this.id,
    required this.fullName,
    required this.role,
    required this.phone,
    required this.email,
    required this.certifications,
    this.photoUrl,
  });

  final String id;
  final String fullName;
  final String role;
  final String phone;
  final String email;
  final List<String> certifications;

  /// Real headshot URL, when available. `null` means the UI should fall
  /// back to an initials avatar.
  final String? photoUrl;

  /// Builds a technician from a `technicians` table row.
  ///
  /// Only `id` and `full_name` are trusted to always be present — every
  /// other column is read with a nullable cast and a display-friendly
  /// fallback, since real rows (unlike the old mock data) can have nulls
  /// in optional columns.
  factory MockTechnician.fromMap(Map<String, dynamic> map) {
    return MockTechnician(
      id: map['id'] as String,
      fullName: map['full_name'] as String,
      role: (map['role'] as String?) ?? 'Not provided',
      phone: (map['phone'] as String?) ?? 'Not provided',
      email: (map['email'] as String?) ?? 'Not provided',
      certifications:
          (map['certifications'] as List?)?.whereType<String>().toList() ?? const [],
      photoUrl: map['photo_url'] as String?,
    );
  }

  String get initials {
    final parts = fullName.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }
}
